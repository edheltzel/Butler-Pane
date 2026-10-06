# Tern × GitButler: design note

Plugin id `gitbutler`. Built on Tern 0.5.1, re-checked on 0.5.2 (the `tern.d.luau` it writes is unchanged), with but 0.22.3, on BigMac.

Files live in `plugin/` (the linked package; `.git` stays at the repo root because Tern reloads plugins on any change inside the package): `gb.luau` (detection, async `but` runner, JSON → model, used by both halves), `host.luau` (workspace and diff blocks), `lenses.luau` (lenses and the spawn filter), `parse.luau` (human-output readers, lenses only), `window.luau` (segment, commands, keys, override, routes), `check.luau` (`luau check.luau` runs the parser checks).

## Is this folder GitButler-managed?

One function, `gb.root(path)` in `gb.luau`, required by both halves:

1. Walk up from `path` to the first `.git`. A `.git` file (a linked worktree) is followed through `gitdir:`, then `commondir`.
2. Managed when `<gitdir>/HEAD` is `ref: refs/heads/gitbutler/…` (`workspace`, or `edit` during `but resolve`) **and** `<commondir>/gitbutler/` exists.
3. Return the worktree root, or `nil`.

The check only stats and reads files, with no process, so it is cheap enough for window handlers (50 ms budget) and fits inside the 2 s host budget. It turns false after `but teardown`, because HEAD leaves `gitbutler/`. Every surface calls it.

It answers "must raw git stay out?", not "does `but` know this project?". `Atlas/Iris`, `GAT/Card2` and `Websites/SIGsite` are on `gitbutler/workspace` but missing from but's project list, so `but status --json` returns `{"error":"setup_required"}`. For those repos the segment reads `GitButler: run but setup`, and the block shows the error.

## Surfaces

| Need | Tern surface | Half |
| --- | --- | --- |
| Status segment (applied branches, unpushed commits) | `tern.chrome.status` reads a cache. `focus`/`cwd`/`command_finished` events and a 30 s timer refresh it with an async `but status --json` | window |
| Workspace block (lanes, uncommitted files, assignments, actions) | `[[blocks]] workspace`. Polls with `tern.process.run` (review-queue pattern), `r` refreshes | host |
| File/commit diff view | `[[blocks]] diff`. The workspace block calls `cx:open("gitbutler://diff?…")`, and `tern.route.link` in the window turns that into `cx:new_block("gitbutler.diff", …, "beside")` | host + window |
| `but status/diff/show/oplog` in a shell | `[[lenses]]`. JSON output is parsed when the command was run with `--json`. Otherwise `parse.luau` reads the human text (your call, lenses only). A `spawn` filter gives new shells `BUT_THEME=dark` and `BUT_PAGER=cat` unless already set. Without them, `but` sends OSC 10/11 color queries and DA1, and its `less` pager turns on keypad mode, and Tern aborts any capture that does that, so no lens could ever render | host |
| Open the workspace from a git action | `tern.override("new_git_block")`: GitButler repo → workspace block, else `false` (Tern's git block) | window |
| Palette and keys | `tern.command` + `keys` (⌥⇧⌘G open, ⌥⇧⌘C commit, ⌥⇧⌘A absorb, ⌥⇧⌘Z undo, ⌥⇧⌘P push, plus unbound rows for the rest). A command opens or focuses the block, then sends it `{ev="action", act=…}` through `cx.session:event`, so the action runs on the block's selection with the block's confirmations | window |
| Raw git block opened on a GitButler repo | `git.*` are view chords, so they can't be overridden (`tern.override` takes only command ids). `pane_created`/`focus` check `cx.session:pane(id)` for `kind = "git"`, run `gb.root(path)`, and toast a warning once per pane | window |

All `but` runs are async (`tern.process.run` with `timeout_ms`), use `-C <root>`, pass `--json`, get empty stdin, and set `NO_COLOR=1`, `GIT_TERMINAL_PROMPT=0`. Each block allows one mutation at a time. Reads time out after 15 s, and push/PR/land after 120 s.

## JSON fields relied on

- `but status -f --json`: `uncommittedChanges[]{cliId,filePath,changeType}`, `stacks[]{cliId,assignedChanges[],branches[]{cliId,name,branchStatus,reviewId,commits[]{cliId,changeId,commitId,message,conflicted,changes[]{cliId,filePath,changeType}},upstreamCommits[]}}`, `upstreamState.behind`, `mergeBase.commitId`. Mutations pass `zz:<path>`, a full `changeId`, or `<changeId>:<path>`, not the snapshot `cliId`.
- `branchStatus`: `completelyUnpushed` means every commit is unpushed, and `nothingToPush` means 0. For `unpushedCommits*`, the segment asks `but push --dry-run --json` for `branches[]{branchName,unpushedCommits}`.
- `but diff <id> --json`: `changes[]{path,status,diff{type,hunks[]{diff}}}`. The hunks are joined into unified text for `tern.ui.diff`.
- `but oplog list --json`: `[]{id,createdAt(ms),details{operation,title,body}}`.
- `but branch list --local --json`: `branches[]` (unapplied branches, for apply).
- Mutation results (`commit`, `absorb`, `undo`, …) are checked by exit status. JSON is used only for messages.

## Action → command

| Action | Command | Confirm |
| --- | --- | --- |
| Commit marked/selected files to a branch | `but commit -b <branch> -m <msg> [zz:<path>…]` | no |
| Move uncommitted file to branch | `but amend -t <branch> zz:<path>` (amends the branch tip) | yes; danger when that branch or one stacked above it is not `completelyUnpushed` (push state re-read before the confirm) |
| Move committed file / commit to branch | `but move <changeId> -b <branch>` (a file is `<changeId>:<path>`) | yes; danger when either branch, or one stacked above it, is not `completelyUnpushed` (push state re-read before the confirm) |
| Absorb | `but absorb [zz:<path>]`; the sheet shows `but absorb --dry-run --json` first | yes; danger when a target commit's branch, or one stacked above it, is not `completelyUnpushed` (push state re-read before the confirm) |
| Reword commit / rename branch | `but reword <changeId or branch name> -m <text>` | danger when the commit's branch or one stacked above it is not `completelyUnpushed` (rename checks only the renamed branch; push state re-read before acting); otherwise no |
| New branch (parallel / stacked) | `but branch new <name> [-A <branch>]` | no |
| Apply / unapply | `but apply <name>` / `but unapply <name>` | unapply: yes |
| Undo / restore oplog entry | `but undo` (aborts if the oplog head is no longer the confirmed entry) / `but oplog restore <sha>` | yes |
| Push / PR / land | `but push <branch>` / `but pr new <branch> -t` / `but land <branch> --yes` | yes |

Marks are file paths, captured before an async file check. Escape cancels a pending file check as well as clearing marks. If a marked path is no longer an uncommitted change, the action stops and those marks are cleared; it does not commit every change. Targeted file actions refuse names containing `:` because but 0.22 interprets them as selector separators and may target another file or hunk. Polling pauses while a sheet is open so a refresh cannot retarget it. An anonymous stack still has only a snapshot CLI id; unapply re-reads status and aborts if that id now labels different commits. Undo re-reads the oplog head and aborts if it moved, because restoring that snapshot would also revert later operations. Oplog restore runs `but oplog restore` on the sha the sheet confirmed. Confirm and pick sheets take only unmodified keys (no shift, ctrl, alt, or meta) and never a paste. A prompt still accepts paste and shift+enter; other ctrl, alt, and meta chords are ignored. Escape cancels every sheet.

## Open questions / findings

1. **There is no CLI assignment in but 0.22.3.** `but rub` is retired, `move`/`squash` reject uncommitted sources ("Cannot pass uncommitted file or hunk as source"), and the TUI has no assign step either. The block shows `assignedChanges` (set by the GUI) read-only. `m` on an uncommitted file amends it into the chosen branch's tip, or commits it there when the branch is empty. `m` on a commit or committed file runs `but move`.
2. **Lenses vs JSON-only:** decided. Lenses parse human text and use JSON when `--json` was typed. Human status output carries push state only as color, so plain `but status` shows no pushed/unpushed badge. `but status --json` does.
3. **Remote hosts:** the status segment runs `but` on the desktop. Panes on a remote host get no segment, but the block still works, since it runs where the panes run.
4. **Unpushed counts for partially pushed branches** come from `push --dry-run`. If it omits a branch, the segment shows `N+`.
5. **`BUT_THEME=dark`** is a fixed default. On a light theme, export `BUT_THEME=light` in your shell rc. The rc runs after the spawn env, so it wins.
