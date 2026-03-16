# codex-sidebar-refresher

Local workaround scripts for making missing Codex Desktop sidebar threads visible again.

Korean version: [README.ko.md](README.ko.md)

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

This repo only reads `state_5.sqlite` and `.codex-global-state.json`. It does not rewrite conversation contents in `sessions/*.jsonl`.

## How the workaround works

`refresh-visible-workspaces.sh` does the following:

1. Reads `electron-saved-workspace-roots` from the global state file.
2. Falls back to `active-workspace-roots` if saved roots are empty.
3. Finds direct threads whose `cwd` exactly matches those roots.
4. Excludes `exec` sessions and subagent threads.
5. Excludes already pinned threads.
6. Rewrites selected `threads.updated_at` values to newer timestamps.
7. Restarts the Codex app so those threads move back into the startup recent set.

So this is not "conversation recovery." It is closer to:

- leave the conversation data alone
- change only recent ordering in `state_5.sqlite`
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

- running `refresh-visible-workspaces.sh` will terminate and relaunch Codex without a quit-confirmation prompt
- a regular terminal is safer than running it inside Codex itself
- a backup is created before any changes are applied
- the script rewrites actual `updated_at` values
- conversation contents are not modified, but recent ordering does change
- already pinned threads are excluded from promotion
- if Codex Desktop changes its internal loading behavior, this workaround may become less useful

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
- rewrites `updated_at` so they rank higher in recents
- does not modify app state JSON beyond reading it
- does not modify session log contents
