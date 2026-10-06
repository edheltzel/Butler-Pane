# Regroup status check

- **Date:** 2026-10-06
- **Source read:** project files in `/Users/ed/Developer/TernGitButler` (`DESIGN.md`, `AGENTS.md`, the plugin code) plus this session's run record (fix and review results). No board or issue tracker was named.

## Counts

- Active projects: 1
- Blocked tasks: 1
- Stalled tasks: 0. There is no earlier regroup file to compare against, so nothing can be called stalled.

## What changed since the previous regroup file

There is no earlier regroup file. This is the first check-in.

## Projects

### TernGitButler (Tern plugin for GitButler)

#### Phase 1: Read-only

- **Status segment.** Done. Percent not stated. It shows applied branches and unpushed commits, and a click opens the workspace block.
- **Workspace block.** Done. Percent not stated. It has lanes per stack, uncommitted files with their assignment, diffs in a reused pane, and refreshes on `r` and every 5 s.
- **Command lenses.** Done. Percent not stated. `but status`, `diff`, `show` and `oplog` render natively by reading the human text (approved) or `--json`.
- **Verification in a real repo by Ed.** Not started. Percent not stated. Every test so far ran against the sandbox at `/tmp/gbs/work`.

#### Phase 2: Actions in the block

- **Commit, move, absorb, reword, new branch, apply/unapply, undo, oplog restore, push, land.** Done. Percent not stated. All were exercised in the sandbox with confirmations.
- **PR against a real forge.** Not started. Percent not stated. Only the no-forge error path was tested.

#### Phase 3: Fit into Tern

- **`new_git_block` override.** Done. Percent not stated. It routes to the workspace block in GitButler repos.
- **Palette commands and keybinds.** Done. Percent not stated. Commands send actions to the block. Keys: ⌥⇧⌘G, C, A, Z, P.
- **Warning for a raw git block.** Done. Percent not stated. The `git.*` actions can't be overridden, so a toast warns when Tern's git block opens on a GitButler repo.

#### Hardening (red-team fixes 1-4, each followed by an adversarial review)

- **Fix 1: stale targets.** Done. Percent not stated. Marks are keyed by path, mutations use stable ids, and colon paths are refused. The re-review found nothing.
- **Fix 2: pin undo.** Done. Percent not stated. Undo aborts if the oplog head moved. The review's liveness finding was fixed with a one-line guard, checked by reading the code but not re-reviewed by an agent.
- **Fix 3: strict confirm keys.** Active. Percent not stated. The fix is applied and proven in the test window; its adversarial review is still running.
- **Fix 4: warn before rewriting pushed history.** Not started. Percent not stated. It is queued after fix 3's review.
- **Lower-priority red-team items.** Backlogged. Percent not stated. Palette action timing, names starting with `-`, Unicode in the lens parser, the 16 MiB output cap, and symlink/remote/cache detection.

#### Repo setup

- **AGENTS.md.** Done. Percent not stated. Written, 87 lines, with GitButler as mandatory.
- **GitButler workspace for the plugin folder.** Blocked. Percent not stated. The folder is not a repo; it waits on Ed approving `git init` and `but setup` (AGENTS.md says ask first).

## Decisions still open from the previous file

There is no earlier regroup file, so there is no open decision on record.
