# codex-sidebar-refresher

Local workaround scripts for making missing Codex Desktop sidebar threads visible again.

Korean version: [README.ko.md](README.ko.md)

## For AI agents

If a user pastes only this repo URL and asks you to fix their Codex Desktop sidebar:

1. **Critical: do NOT run the script from inside Codex Desktop's integrated terminal.** The script force-kills the `Codex` process; if your terminal is a child of Codex, it will die mid-update and leave the database in a partial state. Use Terminal.app, iTerm, or any terminal not spawned by Codex.
2. Confirm the symptoms match `## Why this exists` below.
3. Clone the repo and run:
   ```bash
   git clone https://github.com/chenjingdev/codex-sidebar-refresher.git
   cd codex-sidebar-refresher
   ./scripts/refresh-visible-workspaces.sh --threads-per-root 20
   ```
   Or target one specific project:
   ```bash
   ./scripts/refresh-visible-workspaces.sh \
     --only-root /absolute/path/to/project \
     --threads-per-root 30
   ```
4. The script auto-restarts Codex. Verify the sidebar now lists the threads.
5. If the script reports `rolloutFilesTouched: 0`, something is wrong — investigate before retrying.

## Why this exists

Use this when:

- Codex CLI can still see older conversations, but the Desktop App sidebar cannot
- a workspace should contain more conversations than the app currently shows
- pinning makes a hidden thread appear, but unpinning and restarting hides it again

## What seems to be happening

Based on local investigation of the current Codex Desktop App behavior, the sidebar does not appear to render a workspace's full local history directly.

Instead, it appears to combine:

- saved workspace roots from local app state
- a startup-loaded recent thread subset

That means an older thread can still exist locally and remain visible in Codex CLI, but still fail to appear in the Desktop App sidebar if it falls outside the app's initial recent window.

## About the recent window

In the app version investigated for this repo, the Desktop App appears to request something equivalent to:

`thread/list(limit=50, sortKey=updated_at)`

on startup.

So a workspace thread can still exist in local storage, but fail to show up in the sidebar when:

- its global recent rank is too low
- it is not included in the startup preload set
- the sidebar ends up grouping only that loaded subset

This is an implementation observation, not a public API contract, so future app versions may behave differently.

## Local storage assumptions

This tool expects a local Codex layout roughly like this:

- `~/.codex/state_5.sqlite`
  - SQLite database containing thread metadata
  - this tool reads fields such as `id`, `cwd`, `title`, `updated_at`, and `source`
- `~/.codex/sessions/.../*.jsonl`
  - session event logs containing the actual conversation content
- `~/.codex/.codex-global-state.json`
  - app UI state, including saved workspace roots used by the Desktop sidebar

In short:

- `sessions/*.jsonl` = conversation log data
- `state_5.sqlite` = thread metadata and recent ordering
- `.codex-global-state.json` = saved workspace roots and sidebar-related UI state

This repo reads `state_5.sqlite` and `.codex-global-state.json`, and modifies `threads.updated_at` plus the mtime of the matching `sessions/*.jsonl` files. It does not rewrite conversation contents inside those JSONL files.

## How the workaround works

`refresh-visible-workspaces.sh` does the following:

1. Reads `electron-saved-workspace-roots` from the global state file.
2. Falls back to `active-workspace-roots` if saved roots are empty.
3. Finds direct threads whose `cwd` exactly matches those roots.
4. Excludes `exec` sessions and subagent threads.
5. Excludes already pinned threads.
6. Rewrites selected `threads.updated_at` values to newer timestamps.
7. **Touches the corresponding `sessions/.../*.jsonl` rollout files via `os.utime()` so their mtime matches the new `updated_at`.**
8. Restarts the Codex app so those threads move back into the startup recent set.

### Why step 7 matters

In the app version investigated, Codex Desktop appears to re-derive `threads.updated_at` from the rollout file mtime on startup. If the script only updates the SQLite row, Codex overwrites it back with the file mtime when it relaunches and the promotion has no visible effect.

So the script touches both. The output JSON includes `rolloutFilesTouched` so you can confirm the file side actually ran.

So this is not "conversation recovery." It is closer to:

- leave the conversation data alone
- change `updated_at` in `state_5.sqlite` and the matching rollout file mtime
- make the Desktop App load already-existing local threads again

## Included script

- `scripts/refresh-visible-workspaces.sh`
  - promotes matching direct threads by updating `updated_at`
  - force-restarts the Codex app without showing the quit confirmation dialog

## Requirements

- macOS
- local Codex Desktop App installation
- local Codex data directory
  - default: `~/.codex`
- `sqlite3`
- `/usr/bin/python3`

## Environment variables

- `CODEX_HOME`
  - default: `~/.codex`
- `CODEX_APP_PATH`
  - default: `/Applications/Codex.app`
- `CODEX_APP_CMD`
  - default: `$CODEX_APP_PATH/Contents/MacOS/Codex`
- `CODEX_APP_PROCESS_NAME`
  - default: `Codex`

## Cautions

- **Do not run from inside the Codex Desktop App's integrated terminal.** The script force-kills the `Codex` process; if your shell is a child of that process, it will be killed mid-update and leave the database in a partial state. Use Terminal.app, iTerm, or any terminal not spawned by Codex.
- The script terminates and relaunches Codex without a quit-confirmation prompt.
- A SQLite + state JSON backup is created before any changes are applied (under `~/.codex/repair-backups/`). Rollout file mtimes are not backed up — run `stat -f "%m" <file>` first if you need to restore them later.
- The script rewrites `threads.updated_at` in `state_5.sqlite` AND the mtime of the corresponding `sessions/.../*.jsonl` rollout files. Conversation contents are not modified, but recent ordering and file mtimes do change.
- Already pinned threads are excluded from promotion.
- If Codex Desktop changes its internal loading behavior, this workaround may become less useful.

## Usage

### Promote a few threads per saved workspace root

```bash
./scripts/refresh-visible-workspaces.sh --threads-per-root 3
```

### Promote the most recent matching threads across all saved roots

```bash
./scripts/refresh-visible-workspaces.sh --total-threads 50
```

By default, the script uses `electron-saved-workspace-roots` and falls back to `active-workspace-roots` if needed. The Codex app is restarted automatically after the update.

### Promote threads for only one specific root

```bash
./scripts/refresh-visible-workspaces.sh \
  --only-root /absolute/path/to/project \
  --threads-per-root 5
```

Example:

```bash
./scripts/refresh-visible-workspaces.sh \
  --only-root /Users/chenjing/dev/project \
  --threads-per-root 5
```

## Summary of behavior

`refresh-visible-workspaces.sh`:

- reads saved workspace roots or explicit `--only-root` values
- selects direct threads whose `cwd` exactly matches the root
- excludes `exec`, subagent, and pinned threads
- rewrites `threads.updated_at` so they rank higher in recents
- touches the matching rollout file mtime so Codex does not revert `updated_at` on next startup
- does not modify app state JSON beyond reading it
- does not modify session log contents
