--!strict
-- The window half: the status segment, the commands and keys that open
-- the workspace block, and the `gitbutler://` links the block opens.

local gb = require("./gb")

local WORKSPACE = "gitbutler.workspace"
local DIFF = "gitbutler.diff"
local OPEN = "plugin.gitbutler.open"
local POLL_MS = 30 * 1000
local STALE_MS = 3 * 1000
local READ_TIMEOUT_MS = 15 * 1000
local SWEEP_MS = 10
-- What the status segment shows for one workspace root.
type Summary = {
	branches: number,
	unpushed: number,
	partial: boolean, -- some branch's unpushed count is unknown: show "N+"
	problem: string?, -- `but` failed (setup_required, timeout, …)
	at: number, -- tern.now() of the last answer
}

-- Root of each directory seen, false when it isn't GitButler-managed.
local roots: { [string]: string | false } = {}
local summaries: { [string]: Summary } = {}
local loading: { [string]: boolean } = {}
local tick: TimerHandle? = nil
local sweep_gen = 0
local function root_of(cwd: string?): string?
	if cwd == nil or cwd == "" then
		return nil
	end
	local known = roots[cwd]
	if known == nil then
		known = gb.root(cwd) or false
		roots[cwd] = known
	end
	return if known then known else nil
end

local function focused_cwd(cx: WindowCx): string?
	local id = cx.session:focused()
	if id == nil then
		return nil
	end
	local info = cx.session:pane(id)
	return if info then info.cwd else nil
end

-- Branch names whose unpushed count `but push --dry-run --json` reports.
local function dry_run_counts(data: any): { [string]: number }
	local out: { [string]: number } = {}
	if type(data) == "table" and type(data.branches) == "table" then
		for _, b in data.branches do
			if type(b.branchName) == "string" and type(b.unpushedCommits) == "number" then
				out[b.branchName] = b.unpushedCommits
			end
		end
	end
	return out
end

local function store(root: string, summary: Summary)
	summaries[root] = summary
	loading[root] = nil
	tern.chrome.refresh()
end

-- Reads the workspace at `root` in the background, at most once per
-- STALE_MS unless `force`.
local function fetch(root: string, force: boolean)
	local last = summaries[root]
	if loading[root] or (not force and last and tern.now() - last.at < STALE_MS) then
		return
	end
	loading[root] = true
	local spawn_err = gb.run(root, { "status", "--json" }, READ_TIMEOUT_MS, function(r: gb.Result)
		local model = if r.ok then gb.model(r.data) else nil
		if model == nil then
			store(root, { branches = 0, unpushed = 0, partial = false, problem = r.err or "unreadable status", at = tern.now() })
			return
		end
		local branches, unpushed = 0, 0
		local unknown: { string } = {}
		for _, stack in model.stacks do
			for _, b in stack.branches do
				branches += 1
				local n = gb.unpushed(b)
				if n then
					unpushed += n
				else
					table.insert(unknown, b.name)
				end
			end
		end
		if #unknown == 0 then
			store(root, { branches = branches, unpushed = unpushed, partial = false, at = tern.now() })
			return
		end
		-- Some branches are partly pushed: ask push for exact counts.
		local err = gb.run(root, { "push", "--dry-run", "--json" }, READ_TIMEOUT_MS, function(p: gb.Result)
			local counts = if p.ok then dry_run_counts(p.data) else {}
			local partial = false
			for _, name in unknown do
				local n = counts[name]
				if n then
					unpushed += n
				else
					partial = true
				end
			end
			store(root, { branches = branches, unpushed = unpushed, partial = partial, at = tern.now() })
		end)
		if err then
			store(root, { branches = branches, unpushed = unpushed, partial = true, at = tern.now() })
		end
	end)
	if spawn_err then
		store(root, { branches = 0, unpushed = 0, partial = false, problem = spawn_err, at = tern.now() })
	end
end

-- One poll timer while the focused pane is in a GitButler workspace.
local function track(cx: WindowCx, force: boolean)
	local root = root_of(focused_cwd(cx))
	if root then
		fetch(root, force)
	end
	if root and tick == nil then
		tick = tern.timer(POLL_MS, function(tcx: WindowCx?)
			tick = nil
			if tcx then
				track(tcx, true)
			end
		end)
	elseif root == nil and tick then
		tick:cancel()
		tick = nil
	end
end

-- A reload doesn't emit window_start or focus: read the focused pane now.
tern.timer(0, function(cx: WindowCx?)
	if cx then
		track(cx, false)
	end
end)
tern.on("window_start", function(cx: WindowCx)
	track(cx, false)
end)
tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	track(cx, false)
end)
tern.on("cwd", function(_ev: any, cx: WindowCx)
	track(cx, false)
end)
tern.on("command_finished", function(_ev: CommandFinishedEvent, cx: WindowCx)
	-- A command may have changed whether a folder is managed. Do not
	-- clear the cache first: the formatter must keep the previous entry
	-- until that cwd is overwritten. Probe only the focused cwd here
	-- (`but setup` / `but teardown`, including a child of a cached
	-- parent). Other panes are swept in short timer chunks so this
	-- handler stays inside the 50 ms budget.
	sweep_gen += 1
	local gen = sweep_gen
	local focused = focused_cwd(cx)
	if type(focused) == "string" and focused ~= "" then
		roots[focused] = gb.root(focused) or false
	end
	track(cx, true)
	tern.chrome.refresh()

	local pending: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(focused) == "string" and focused ~= "" then
		seen[focused] = true
	end
	for _, p in cx.session:panes() do
		local dir = p.cwd
		if type(dir) == "string" and dir ~= "" and not seen[dir] then
			seen[dir] = true
			table.insert(pending, dir)
		end
	end

	local function drop_absent(tcx: WindowCx)
		local live: { [string]: boolean } = {}
		for _, p in tcx.session:panes() do
			local dir = p.cwd
			if type(dir) == "string" and dir ~= "" then
				live[dir] = true
			end
		end
		for cwd in roots do
			if not live[cwd] then
				roots[cwd] = nil
			end
		end
	end

	local i = 1
	local function step(tcx: WindowCx?)
		if gen ~= sweep_gen or tcx == nil then
			return
		end
		local start = tern.now()
		local changed = false
		local focused_now = focused_cwd(tcx)
		local focused_changed = false
		while i <= #pending do
			local dir = pending[i]
			i += 1
			local nextv = gb.root(dir) or false
			if roots[dir] ~= nextv then
				changed = true
				focused_changed = focused_changed or dir == focused_now
			end
			roots[dir] = nextv
			if tern.now() - start >= SWEEP_MS then
				break
			end
		end
		if focused_changed then
			-- Focus may have landed here before the sweep did: start the
			-- fetch and poll that the focus handler skipped.
			track(tcx, true)
		end
		if changed then
			tern.chrome.refresh()
		end
		if i <= #pending then
			tern.timer(0, step)
		else
			drop_absent(tcx)
		end
	end

	if #pending > 0 then
		tern.timer(0, step)
	else
		drop_absent(cx)
	end
end)

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local known = if pane.cwd then roots[pane.cwd] else nil
	if not known then
		return nil
	end
	local s = summaries[known]
	if s == nil then
		return { { text = "GitButler", icon = "git-branch", tone = "muted", command = OPEN } }
	end
	if s.problem then
		local text = if string.find(s.problem, "No GitButler project", 1, true)
			then "GitButler: run but setup"
			else "GitButler: " .. (string.match(s.problem, "^[^\n]*") or "error")
		return { { text = text, icon = "git-branch", tone = "warning", command = OPEN } }
	end
	local text = string.format(
		"%d %s · %d%s unpushed",
		s.branches,
		if s.branches == 1 then "branch" else "branches",
		s.unpushed,
		if s.partial then "+" else ""
	)
	return { { text = text, icon = "git-branch", tone = if s.unpushed > 0 then "accent" else "muted", command = OPEN } }
end)

-- The workspace block for `root`: the one this window shows (focused),
-- else a new one. Returns its pane and whether it was already running.
local function open_workspace(cx: WindowCx, root: string): (number?, boolean)
	for _, pane in cx.session:panes() do
		if pane.block == WORKSPACE and pane.exited == nil and root_of(pane.cwd) == root then
			cx.layout:focus(pane.pane)
			return pane.pane, true
		end
	end
	local pane = cx:new_block(WORKSPACE, { root }, "beside")
	if pane == nil then
		cx:toast("error", "GitButler block is not loaded on this host", "Install the plugin where your panes run.")
	end
	return pane, false
end

local function focused_root(cx: WindowCx): string?
	local root = root_of(focused_cwd(cx))
	if root == nil then
		cx:toast("info", "Not a GitButler workspace", focused_cwd(cx) or "No focused pane")
	end
	return root
end

tern.command({
	id = "open",
	title = "Open GitButler workspace",
	icon = "git-branch",
	keys = { "cmd+alt+shift+g" },
	run = function(cx: WindowCx)
		local root = focused_root(cx)
		if root then
			open_workspace(cx, root)
		end
	end,
})

-- Palette commands for the block's actions: open (or focus) the workspace,
-- then hand it the action as a view event, so it runs on the block's
-- selection with the block's confirmations. A block that is only now
-- starting gets the event once its first view is up.
local ACTIONS = {
	{ "commit", "GitButler: Commit to a branch…", "cmd+alt+shift+c" },
	{ "absorb", "GitButler: Absorb uncommitted changes", "cmd+alt+shift+a" },
	{ "undo", "GitButler: Undo last operation", "cmd+alt+shift+z" },
	{ "oplog", "GitButler: Restore from oplog…", nil },
	{ "move", "GitButler: Move selection to a branch…", nil },
	{ "reword", "GitButler: Reword commit / rename branch…", nil },
	{ "branch", "GitButler: New parallel branch…", nil },
	{ "stack", "GitButler: New stacked branch…", nil },
	{ "apply", "GitButler: Apply a branch…", nil },
	{ "unapply", "GitButler: Unapply selected stack…", nil },
	{ "push", "GitButler: Push selected branch…", "cmd+alt+shift+p" },
	{ "pr", "GitButler: Open pull request…", nil },
	{ "land", "GitButler: Land selected branch…", nil },
}

local function send_action(cx: WindowCx, pane: number, act: string)
	cx.session:event(pane, { ev = "action", act = act })
end

for _, a in ACTIONS do
	local act, title, key = a[1] :: string, a[2] :: string, a[3]
	tern.command({
		id = act,
		title = title,
		icon = "git-branch",
		keys = if key then { key :: string } else nil,
		run = function(cx: WindowCx)
			local root = focused_root(cx)
			if root == nil then
				return
			end
			local pane, existed = open_workspace(cx, root)
			if pane and existed then
				send_action(cx, pane, act)
			elseif pane then
				tern.timer(1500, function(tcx: WindowCx?)
					if tcx then
						send_action(tcx, pane :: number, act)
					end
				end)
			end
		end,
	})
end

-- Tern's git block writes with raw git (stage, commit, checkout, stash),
-- which a GitButler workspace must not take. Its `git.*` keys are view
-- chords that plugins can't override, so the commands that open it are
-- routed to the workspace block instead, and a git block opened some other
-- way on a GitButler repo gets a warning.
tern.override("new_git_block", function(cx: WindowCx): boolean
	local root = root_of(focused_cwd(cx))
	if root == nil then
		return false
	end
	open_workspace(cx, root)
	return true
end)

local warned: { [number]: boolean } = {}

local function check_git_block(cx: WindowCx, pane: number)
	if warned[pane] then
		return
	end
	local info = cx.session:pane(pane)
	if info == nil or info.kind ~= "git" then
		return
	end
	local root = gb.root(info.path or info.cwd)
	if root then
		warned[pane] = true
		cx:toast(
			"error",
			"Tern's git block is open on a GitButler workspace",
			"It stages, commits and checks out with raw git. Use GitButler (⌥⇧⌘G) for " .. root
		)
	end
end

tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
	check_git_block(cx, ev.pane)
end)
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if ev.pane then
		check_git_block(cx, ev.pane)
	end
end)
tern.on("pane_closed", function(ev: PaneEvent, _cx: WindowCx)
	warned[ev.pane] = nil
end)

-- `gitbutler://diff?root=…&id=…&label=…`, opened by the workspace block.
local function unescape(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	local q = string.match(url, "%?(.*)$") or ""
	for k, v in string.gmatch(q, "([^&=]+)=([^&]*)") do
		out[k] = unescape(v)
	end
	return out
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, 16) ~= "gitbutler://diff" then
		return nil
	end
	local q = query(link.url)
	if q.root == nil or q.id == nil then
		return { handled = true }
	end
	local args = { q.root, q.id, q.label or q.id }
	-- One diff pane per tab, replaced in place (split it, close the old
	-- one); focus stays where the link came from so the workspace keeps
	-- the keys.
	local from = link.pane or cx.session:focused()
	local tab = if from then cx.session:tab_of(from) else nil
	local old: number? = nil
	for _, pane in cx.session:panes() do
		if pane.block == DIFF and tab and cx.session:tab_of(pane.pane) == tab then
			old = pane.pane
			break
		end
	end
	local opened: number? = nil
	if old then
		opened = cx.layout:split(old, "down", { block = DIFF, args = args })
		if opened then
			cx.layout:close(old)
		end
	else
		opened = cx:new_block(DIFF, args, "beside")
	end
	if opened == nil then
		cx:toast("error", "GitButler diff block is not loaded on this host")
	elseif from then
		cx.layout:focus(from)
	end
	return { handled = true }
end)
