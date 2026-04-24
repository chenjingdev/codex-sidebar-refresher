#!/bin/zsh
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
STATE_FILE="$CODEX_HOME/.codex-global-state.json"
DB_FILE="$CODEX_HOME/state_5.sqlite"
CODEX_APP_PATH="${CODEX_APP_PATH:-/Applications/Codex.app}"
APP_CMD="${CODEX_APP_CMD:-$CODEX_APP_PATH/Contents/MacOS/Codex}"
APP_PROCESS_NAME="${CODEX_APP_PROCESS_NAME:-Codex}"

typeset -a ONLY_ROOTS=()
THREADS_PER_ROOT=1
TOTAL_THREADS=0

is_codex_running() {
  pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1
}

quit_codex_if_running() {
  if ! is_codex_running; then
    return 0
  fi

  for _ in {1..50}; do
    if ! is_codex_running; then
      return 0
    fi
    pkill -TERM -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true
    sleep 0.1
  done

  pkill -KILL -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! is_codex_running; then
      return 0
    fi
    sleep 0.1
  done

  echo "Failed to stop Codex app process." >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  refresh-visible-workspaces.sh [options]

Behavior:
  - uses electron-saved-workspace-roots from ~/.codex/.codex-global-state.json by default
  - falls back to active-workspace-roots if saved roots are empty
  - if --only-root is provided, only those roots are used
  - refreshes direct threads whose cwd exactly matches each root
  - ignores exec sessions and subagent threads
  - only updates thread ordering in state_5.sqlite
  - force-restarts Codex around the update without showing the quit prompt

Options:
  --only-root /abs/path   Refresh only these roots (repeatable)
  --threads-per-root N    Refresh up to N direct threads per root (default: 1)
  --total-threads N       Refresh the most recent N direct threads across selected roots
  -h, --help              Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --only-root)
      [[ $# -ge 2 ]] || { echo "--only-root requires a value" >&2; exit 1; }
      ONLY_ROOTS+=("$2")
      shift 2
      ;;
    --threads-per-root)
      [[ $# -ge 2 ]] || { echo "--threads-per-root requires a value" >&2; exit 1; }
      THREADS_PER_ROOT="$2"
      shift 2
      ;;
    --total-threads)
      [[ $# -ge 2 ]] || { echo "--total-threads requires a value" >&2; exit 1; }
      TOTAL_THREADS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$THREADS_PER_ROOT" =~ ^[0-9]+$ ]] || (( THREADS_PER_ROOT < 1 )); then
  echo "--threads-per-root must be a positive integer" >&2
  exit 1
fi

if [[ ! "$TOTAL_THREADS" =~ ^[0-9]+$ ]] || (( TOTAL_THREADS < 0 )); then
  echo "--total-threads must be a non-negative integer" >&2
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Missing state file: $STATE_FILE" >&2
  exit 1
fi

if [[ ! -f "$DB_FILE" ]]; then
  echo "Missing state DB: $DB_FILE" >&2
  exit 1
fi

quit_codex_if_running

BACKUP_DIR="$CODEX_HOME/repair-backups/refresh-visible-workspaces-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

/usr/bin/python3 - "$STATE_FILE" "$DB_FILE" "$BACKUP_DIR" "$THREADS_PER_ROOT" "$TOTAL_THREADS" "${ONLY_ROOTS[@]}" <<'PY'
import json
import os
import shutil
import sqlite3
import sys
from pathlib import Path
from typing import Optional


def normalize_root(root: str) -> str:
    return root.rstrip("/") or "/"


def load_roots(state: dict, only_roots: list[str]) -> list[str]:
    ordered: list[str] = []

    def add(root: Optional[str]) -> None:
        if not isinstance(root, str) or not root:
            return
        normalized = normalize_root(root)
        if normalized not in ordered:
            ordered.append(normalized)

    if only_roots:
        for root in only_roots:
            add(root)
        return ordered

    for root in state.get("electron-saved-workspace-roots") or []:
        add(root)

    if ordered:
        return ordered

    for root in state.get("active-workspace-roots") or []:
        add(root)

    return ordered


def get_current_rank_map(conn: sqlite3.Connection, ids: list[str]) -> dict[str, int]:
    if not ids:
        return {}

    placeholders = ",".join("?" for _ in ids)
    sql = f"""
        WITH ranked AS (
          SELECT
            id,
            ROW_NUMBER() OVER (ORDER BY updated_at DESC, id DESC) AS rank
          FROM threads
          WHERE archived = 0
        )
        SELECT id, rank
        FROM ranked
        WHERE id IN ({placeholders})
    """
    return {thread_id: rank for thread_id, rank in conn.execute(sql, ids)}


def backup_sqlite(source_db: Path, backup_db: Path) -> None:
    src = sqlite3.connect(source_db)
    dest = sqlite3.connect(backup_db)
    try:
        src.backup(dest)
    finally:
        dest.close()
        src.close()


def is_eligible(row: sqlite3.Row, pinned_ids: set[str]) -> bool:
    return row["source"] != "exec" and row["id"] not in pinned_ids


state_path = Path(sys.argv[1])
db_path = Path(sys.argv[2])
backup_dir = Path(sys.argv[3])
threads_per_root = int(sys.argv[4])
total_threads = int(sys.argv[5])
only_roots = sys.argv[6:]

state = json.loads(state_path.read_text(encoding="utf-8"))
roots = load_roots(state, only_roots)
pinned_ids = set(state.get("pinned-thread-ids") or [])

if not roots:
    print(json.dumps({"error": "No active workspace roots found to promote."}, ensure_ascii=False, indent=2))
    sys.exit(1)

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
all_rows = list(
    conn.execute(
        """
        SELECT id, cwd, updated_at, title, source, rollout_path
        FROM threads
        WHERE archived = 0
          AND source NOT LIKE '%parent_thread_id%'
        ORDER BY updated_at DESC, id DESC
        """
    )
)

selected_by_root: dict[str, list[sqlite3.Row]] = {root: [] for root in roots}

if total_threads > 0:
    remaining = total_threads
    for row in all_rows:
        if remaining <= 0:
            break
        if not is_eligible(row, pinned_ids):
            continue
        if row["cwd"] not in selected_by_root:
            continue
        selected_by_root[row["cwd"]].append(row)
        remaining -= 1
else:
    for root in roots:
        direct_rows = [
            row
            for row in all_rows
            if row["cwd"] == root and is_eligible(row, pinned_ids)
        ]
        titled_rows = [row for row in direct_rows if (row["title"] or "").strip()]
        untitled_rows = [row for row in direct_rows if not (row["title"] or "").strip()]
        selected_by_root[root] = (titled_rows + untitled_rows)[:threads_per_root]

selected_rows: list[sqlite3.Row] = []
if total_threads > 0:
    for row in all_rows:
        if row["cwd"] not in selected_by_root:
            continue
        if any(selected["id"] == row["id"] for selected in selected_by_root[row["cwd"]]):
            selected_rows.append(row)
else:
    for index in range(threads_per_root):
        for root in roots:
            rows = selected_by_root[root]
            if index < len(rows):
                selected_rows.append(rows[index])

if not selected_rows:
    print(json.dumps({"error": "No eligible direct threads found for selected roots."}, ensure_ascii=False, indent=2))
    sys.exit(1)

selected_id_list = [row["id"] for row in selected_rows]
rank_before = get_current_rank_map(conn, selected_id_list)
max_updated_at = conn.execute(
    "SELECT COALESCE(MAX(updated_at), 0) FROM threads WHERE archived = 0"
).fetchone()[0]

updates = []
next_updated_at = max_updated_at + len(selected_rows)
for index, row in enumerate(selected_rows, start=1):
    updates.append(
        {
            "id": row["id"],
            "cwd": row["cwd"],
            "title": row["title"],
            "rolloutPath": row["rollout_path"],
            "oldUpdatedAt": row["updated_at"],
            "newUpdatedAt": next_updated_at,
            "oldRank": rank_before.get(row["id"]),
            "predictedRank": index,
        }
    )
    next_updated_at -= 1

shutil.copy2(state_path, backup_dir / ".codex-global-state.json")
backup_sqlite(db_path, backup_dir / "state_5.sqlite")

conn.execute("BEGIN IMMEDIATE")
try:
    for update in updates:
        conn.execute(
            "UPDATE threads SET updated_at = ? WHERE id = ?",
            (update["newUpdatedAt"], update["id"]),
        )
    conn.commit()
except Exception:
    conn.rollback()
    raise

rollout_touched = 0
rollout_missing = 0
for update in updates:
    rollout_path = update.get("rolloutPath")
    if not rollout_path:
        rollout_missing += 1
        continue
    path = Path(rollout_path)
    if not path.exists():
        rollout_missing += 1
        continue
    try:
        os.utime(path, (update["newUpdatedAt"], update["newUpdatedAt"]))
        rollout_touched += 1
    except OSError:
        rollout_missing += 1

rank_after = get_current_rank_map(conn, selected_id_list)
for update in updates:
    update["newRank"] = rank_after.get(update["id"])

print(
    json.dumps(
        {
            "promotedThreadCount": len(updates),
            "rolloutFilesTouched": rollout_touched,
            "rolloutFilesMissing": rollout_missing,
            "backupDir": str(backup_dir),
        },
        ensure_ascii=False,
    )
)
PY

open -a "$CODEX_APP_PATH"
