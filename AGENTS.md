# AGENTS.md

A Tern plugin (Luau) that teaches Tern about GitButler: a status segment, a workspace block, a diff block, command lenses, and actions, all driven by the `but` CLI. Design and findings: `DESIGN.md`.

## GitButler is mandatory

This repo is a GitButler workspace (`gitbutler/workspace`, target `gb-local/main`, no remote yet), and the plugin requires `but` at run time.

- **VCS in this repo:** use `but` for every write: `but commit -b <branch> -m "<msg>" <ids>`, `but push <branch>`, `but pr new <branch>`. Never run `git add`, `commit`, `checkout`, `switch`, `merge`, `rebase`, `reset`, `stash`, `cherry-pick` or `push`. Read-only git (`git log`, `git show`, `git diff`, `git blame`) is fine. Follow `skill://but`.
- If HEAD is ever not `gitbutler/workspace`, stop and ask. Do not work around it with plain git or `but teardown`.
- **Plugin runtime:** `but` (tested with 0.22.3) must be installed on the machine that runs the panes. `gb.luau` looks for it in `PATH`, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
- Never add an agent as a commit co-author.

## Commands

- Link into Tern (reloads on every save): `tern plugin link plugin` (link `plugin/`, never the repo root)
- Status and load errors: `tern plugin list` (host half); window-half errors appear in `~/Library/Logs/Tern/tern.log`
- Force reload: `tern plugin reload`
- Regenerate types after a Tern upgrade: `tern plugin types plugin` (writes `plugin/tern.d.luau`; don't hand-edit it)
- Parser check: `cd plugin && luau check.luau` (must print `parse: ok`)
- Syntax check: `cd plugin && luau-analyze host.luau lenses.luau gb.luau window.luau parse.luau 2>&1 | grep -i syntax` (empty output means clean; the type errors it reports are expected noise, because luau-lsp/luau-analyze can't load `tern.d.luau`)
- Logs: `~/Library/Logs/Tern/tern-daemon.log` (host half, `plugin handler failed`), `~/Library/Logs/Tern/tern.log` (window half)

## Repository structure

- `plugin/`: the Tern package, and the only directory linked into Tern
  - `plugin.toml`: manifest declaring the `workspace` and `diff` blocks and the `status`, `diff`, `show` and `oplog` lenses
  - `gb.luau`: shared by both halves: `gb.root` (managed-folder detection), `gb.run` (async `but` runner), JSON → model helpers
  - `host.luau`: host half: the workspace block (lanes, sheets, actions) and the diff block
  - `lenses.luau`: command lenses plus the `spawn` filter (`BUT_THEME`, `BUT_PAGER`)
  - `parse.luau`: pure readers for `but`'s human output, used only by the lenses
  - `window.luau`: window half: status segment, palette commands and keys, `new_git_block` override, `gitbutler://diff` link route, git-block warning
  - `check.luau`: runnable assertions for `parse.luau`
- `DESIGN.md`: surfaces, JSON fields relied on, action → command map, open findings
- `regroup/`: dated status check-ins (append-only; never edit or delete an old one)

## Architecture boundaries

- Read GitButler state only with `but … --json`. The one exception is `lenses.luau`/`parse.luau`, which read the human text of a command the user typed (user-approved).
- Every write goes through `but` via `gb.run`. Never call raw git, and never use `cx.git` mutations (`stage`, `commit`, `checkout`, `stash_*`, `create_branch`).
- Host handlers have a 2 s budget: start processes only with `gb.run` (async, `timeout_ms`). Never block or loop on I/O.
- Window handlers have a 50 ms budget, and chrome formatters have 4 ms. Formatters read caches only; they never touch disk or processes.
- Every surface uses `gb.root` to decide whether a folder is GitButler-managed. Don't add a second check.
- `parse.luau` stays free of `tern` so `luau check.luau` can run it.
- Host-only APIs (`tern.block`, `tern.lens`, `tern.pane`) stay out of `window.luau`, and window-only APIs (`tern.command`, `tern.chrome`, `tern.route`, `cx.session`) stay out of the host files.

## Coding standards (project-specific)

- Every file is `--!strict` Luau. Set node props through a local (`local p = node.p or {}; …; node.p = p`).
- Destructive actions (undo, oplog restore, unapply, land, history rewrites) open a `confirm` sheet showing the exact `but` command, with `danger = true`. Danger sheets accept only an explicit `y`.
- Pass `but` arguments as an argv list (no shell). Mutations add `--json` and are checked by exit status.
- Async callbacks must check liveness (`running[pane] == state` / `pane_alive`) before touching state or sending effects.
- No em dashes in comments or docs.

## Testing

Run tests in the scratch repo and an isolated Tern, never in real repos.

- Sandbox repo (recreate if `/tmp` was cleared):
  `mkdir -p /tmp/gbs && cd /tmp/gbs && git init -q --bare remote.git && git init -q -b main work && cd work && echo hi > a.txt && git add . && git commit -qm initial && git remote add origin /tmp/gbs/remote.git && git push -q -u origin main && but setup`
  (Plain git is allowed here only to seed the scratch repo before `but setup`.)
- Isolated Tern: `printf '{"shell":"/opt/homebrew/bin/fish","status_bar":true}\n' > /tmp/ttc/settings.json`, `TERN_CONFIG_DIR=/tmp/ttc tern plugin link plugin`, then from `/tmp/ttc` run `TERN_CONFIG_DIR=/tmp/ttc TERN_DAEMON_SOCKET=/tmp/ttc/daemon.sock tern --control /tmp/ttc/ctl.sock /tmp/gbs/work` (long-running).
- Drive it with `TERN_CONFIG_DIR=/tmp/ttc TERN_DAEMON_SOCKET=/tmp/ttc/daemon.sock`:
  - `tern ls`
  - `tern send <pane> keys enter` / `tern send <pane> text c`
  - `timeout 8 tern ctl --control /tmp/ttc/ctl.sock plugins run plugin.gitbutler.open`
  - `timeout 8 tern ctl --control /tmp/ttc/ctl.sock shot NAME` (writes `/tmp/ttc/target/shots/tern/live/NAME.png`)
- Verify each mutation with `but status --json` in `/tmp/gbs/work`.
- Lenses only appear in shells spawned after the plugin loaded (they need the spawn env). Test them in a new tab.

## Gotchas

- Saving any file under `plugin/` reloads every plugin in the user's real Tern as well as the test window. A reload that fails mid-edit kills open blocks; reopen them.
- Tern watches the linked package recursively, and `.git` writes count as changes (measured: each one reloads every plugin). That is why the package lives in `plugin/` with `.git` at the repo root. Never move plugin files to the root or link the root, or every `but` call in this repo will reload Tern's plugins.
- `tern ctl wait` and `tern ctl type` can hang: wrap `ctl` calls in `timeout`, and use `tern send` for keys.
- A plugin reload does not emit `window_start`/`focus`. Window state is re-bootstrapped with `tern.timer(0, …)`.
- `but` 0.22.3 cannot assign an uncommitted file to a branch without committing it (`rub` is retired). See `DESIGN.md`.
- CLI ids (`nk`, `ymn`, `zn:n`) are snapshot-local. Don't hold them across a refresh for a later mutation.

## Boundaries

- **Never:** raw git writes (see above), mutating a real repo while testing, editing `tern.d.luau` by hand, or editing `CHANGELOG.md` or other generated files.
- **Ask first:** new `[[lenses]]` match patterns (a claim also blocks Tern's built-in lens), changes to the spawn filter (it affects every shell Tern starts), new default keybinds, and adding a remote or changing the `gb-local/main` target.

## References

- `DESIGN.md`: design note and findings
- Tern SDK: https://docs.stencil.so/tern/index.html (Blocks, Command Lenses, Host Hooks, Chrome, Commands, API Reference; append `.md` to any page for markdown)
- Example plugins: https://github.com/stencil-hq/tern-sdk (`plugins/examples/`)
- GitButler JSON: https://docs.gitbutler.com/cli-guides/cli-tutorial/scripting; CLI rules: `skill://but`
