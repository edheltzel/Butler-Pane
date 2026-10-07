--!strict
-- The host half: the workspace block (one lane per applied stack, plus the
-- uncommitted changes and where each is assigned), the diff block, and the
-- command lenses (lenses.luau). Blocks read `but … --json` in the background.

local gb = require("./gb")
local ui = tern.ui
local letter = gb.letter
local STATUS_TEXT = gb.STATUS_TEXT

require("./lenses")

local POLL_MS = 5 * 1000
local READ_TIMEOUT_MS = 15 * 1000

-- One selectable line of the workspace: a file, a branch, a commit or a
-- committed file. `id` is the short CLI id shown in the list. Mutations
-- pass a stable ref (`zz:<path>`, full changeId) because CLI ids are
-- snapshot-local and a later `but` resolves them against a new snapshot.
type Row = {
	key: string,
	kind: string, -- "file" | "branch" | "commit" | "cfile"
	lane: number,
	id: string,
	label: string,
	branch: string?, -- the branch it belongs to (branch, commit and cfile rows)
	path: string?,
	change: string?,
	changeId: string?, -- full change id of a commit, or of a committed file's commit
	message: string?, -- a commit's full message
}

-- A choice in a picker or list sheet.
type Option = { label: string, value: string, detail: string? }

-- The sheet over the workspace while an action asks for something:
-- `prompt` (text), `pick` (one of `options`), `confirm` (y/n, with the
-- exact `but` command shown) or `help`.
type Sheet = {
	kind: string,
	title: string,
	body: { string }?,
	command: string?,
	danger: boolean?,
	text: string?,
	options: { Option }?,
	index: number?,
	done: ((value: string) -> ())?,
}

type State = {
	cx: BlockCx,
	root: string,
	model: gb.Model?,
	seen: string?, -- the last status JSON, to skip renders when nothing changed
	reads: number, -- status reads started before this are dropped
	rows: { Row },
	lanes: { { Row } },
	cursor: string?,
	marked: { [string]: boolean }, -- uncommitted file paths, not CLI ids
	loading: boolean,
	fetched: number?,
	problem: string?,
	timer: TimerHandle?,
	sheet: Sheet?,
	busy: string?, -- what the running mutation is doing
	notice: { tone: string, text: string }?,
}

local running: { [number]: State } = {}

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function pane_alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- This run is still the block's current one, and the pane still exists.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	if pane_alive(state.cx.pane) then
		return true
	end
	running[state.cx.pane] = nil
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	return false
end

-- Keys become node ids (`main.lanes.L2.rows.<key>`): keep them to safe characters.
local function key_of(kind: string, id: string): string
	return kind .. "-" .. (string.gsub(id, "[^%w_:%-]", "_"))
end

-- Rows by lane: lane 1 is the uncommitted changes, then one per stack.
local function build_rows(state: State)
	local model = state.model
	local lanes: { { Row } } = {}
	local rows: { Row } = {}
	local function add(lane: number, row: Row)
		lanes[lane] = lanes[lane] or {}
		table.insert(lanes[lane], row)
		table.insert(rows, row)
	end
	lanes[1] = {}
	if model then
		for _, f in model.unassigned do
			add(1, { key = key_of("f", f.id), kind = "file", lane = 1, id = f.id, label = f.path, path = f.path, change = f.change })
		end
		for i, stack in model.stacks do
			local lane = i + 1
			lanes[lane] = {}
			for _, f in stack.assigned do
				add(lane, { key = key_of("a", f.id), kind = "file", lane = lane, id = f.id, label = f.path, path = f.path, change = f.change })
			end
			for _, b in stack.branches do
				local name = gb.label(b)
				add(lane, { key = key_of("b", b.id), kind = "branch", lane = lane, id = if b.name ~= "" then b.name else b.id, label = name, branch = b.name })
				for _, c in b.commits do
					add(lane, { key = key_of("c", c.id), kind = "commit", lane = lane, id = c.id, label = c.title, branch = b.name, changeId = c.changeId, message = c.message })
					for _, f in c.files do
						add(lane, { key = key_of("cf", f.id), kind = "cfile", lane = lane, id = f.id, label = f.path, branch = b.name, path = f.path, change = f.change, changeId = c.changeId })
					end
				end
			end
		end
	end
	state.lanes, state.rows = lanes, rows
	local found = false
	for _, r in rows do
		found = found or r.key == state.cursor
	end
	if not found then
		state.cursor = if rows[1] then rows[1].key else nil
	end
end

local function index_of(state: State): number
	for i, r in state.rows do
		if r.key == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: State): Row?
	return state.rows[index_of(state)]
end

local function refresh(state: State)
	-- A sheet's closure already captured its targets. Swapping the model
	-- under it can retarget the action, so skip the read until it closes.
	if not alive(state) or state.loading or state.sheet ~= nil or state.busy ~= nil then
		return
	end
	state.loading = true
	local token = state.reads
	local err = gb.run(state.root, { "status", "-f", "--json" }, READ_TIMEOUT_MS, function(r: gb.Result)
		if not alive(state) then
			return
		end
		state.loading = false
		if token ~= state.reads or state.sheet ~= nil or state.busy ~= nil then
			state.cx:render()
			return
		end
		state.fetched = os.time()
		local model = if r.ok then gb.model(r.data) else nil
		if model == nil then
			state.problem = r.err or "but status printed something other than a workspace"
		else
			state.problem = nil
			local text = tern.json.encode(r.data)
			if text ~= state.seen then
				state.seen = text
				state.model = model
				build_rows(state)
			end
		end
		state.cx:render()
	end)
	if err then
		state.loading = false
		state.problem = err
	end
end

local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(POLL_MS, function()
		state.timer = nil
		if alive(state) then
			refresh(state)
			poll(state)
		end
	end)
end

local function escape(s: string): string
	return (string.gsub(s, "[^%w%-%._~/]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Opens the diff of a row in the diff block, through the window's link route.
local function open_diff(state: State, cx: BlockCx)
	local row = selected(state)
	if row == nil then
		return
	end
	local label = if row.kind == "commit" then row.id .. " " .. row.label else row.label
	cx:open(string.format("gitbutler://diff?root=%s&id=%s&label=%s", escape(state.root), escape(row.id), escape(label)))
end

-- Branch names each uncommitted path is assigned to.
local function assignments(model: gb.Model): { [string]: string }
	local out: { [string]: string } = {}
	for _, stack in model.stacks do
		local top = stack.branches[1]
		for _, f in stack.assigned do
			out[f.path] = if top then gb.label(top) else stack.id
		end
	end
	return out
end

local function item(state: State, row: Row, model: gb.Model, assigned: { [string]: string }): Item
	if row.kind == "file" then
		local mark = if row.path and state.marked[row.path] then ui.span("● ", "accent") else ui.span("  ")
		local where = assigned[row.label]
		return {
			label = { mark, ui.span(letter(row.change or "") .. " ", "warning mono"), ui.span(row.id .. " ", "muted mono"), row.label },
			value = if row.lane == 1
				then (if where then ui.span("→ " .. where, "accent") else ui.span("unassigned", "muted"))
				else ui.span("assigned", "accent"),
			icon = "file",
		}
	elseif row.kind == "branch" then
		local b: gb.Branch? = nil
		for _, stack in model.stacks do
			for _, candidate in stack.branches do
				if key_of("b", candidate.id) == row.key then
					b = candidate
				end
			end
		end
		local status = if b then STATUS_TEXT[b.status] else nil
		local value: { Span | string } = {}
		if b and b.review then
			table.insert(value, ui.span("PR " .. b.review .. "  ", "info"))
		end
		if b and b.upstream > 0 then
			table.insert(value, ui.span(b.upstream .. " upstream  ", "warning"))
		end
		if status then
			table.insert(value, ui.span(status[1], status[2]))
		end
		return { label = { ui.span(row.label, "strong") }, value = value, icon = "git-branch" }
	elseif row.kind == "commit" then
		return {
			label = { ui.span("  " .. row.id .. " ", "muted mono"), row.label },
			icon = "git-commit",
		}
	end
	return {
		label = { ui.span("      " .. letter(row.change or "") .. " ", "muted mono"), ui.span(row.id .. " ", "muted mono"), ui.span(row.label, "muted") },
		icon = "file",
	}
end

local function lane_head(state: State, lane: number, model: gb.Model): Spans
	if lane == 1 then
		return { ui.span("Uncommitted", "strong"), ui.span("  " .. #model.unassigned, "muted num") }
	end
	local stack = model.stacks[lane - 1]
	local names: { string } = {}
	for _, b in stack.branches do
		table.insert(names, gb.label(b))
	end
	local head: { Span | string } = { ui.span(names[1] or stack.id, "strong") }
	if #names > 1 then
		table.insert(head, ui.span("  stack of " .. #names, "muted"))
	end
	return head
end

local function lanes_view(state: State, model: gb.Model): Node
	local assigned = assignments(model)
	local cards: { Node } = {}
	local current = selected(state)
	for lane, rows in state.lanes do
		local items: { Item } = {}
		for _, row in rows do
			table.insert(items, item(state, row, model, assigned))
		end
		local list = ui.list(items)
		local kids = list.c or {}
		for i, row in rows do
			local p: { [string]: any } = kids[i].p or {}
			p.key = row.key
			kids[i].p = p
		end
		local lp: { [string]: any } = list.p or {}
		lp.key = "rows"
		lp.empty = { ui.span(if lane == 1 then "No uncommitted changes." else "No commits yet.", "muted") }
		if current and current.lane == lane then
			lp.selected = "main.lanes.L" .. lane .. ".rows." .. current.key
		end
		list.p = lp
		local card = ui.card(lane_head(state, lane, model), { list })
		local cp: { [string]: any } = card.p or {}
		cp.key = "L" .. lane
		cp.tone = if current and current.lane == lane then "accent" else nil
		card.p = cp
		table.insert(cards, card)
	end
	local lanes = if state.cx.cols >= 140 then ui.row(cards) else ui.col(cards)
	local p: { [string]: any } = lanes.p or {}
	p.key = "lanes"
	lanes.p = p
	return lanes
end

local KEYS_HELP = "↑↓ move  ←→ lanes  ⏎ diff  space mark  c commit  m move  A absorb  e reword  n/N branch  a/u apply/unapply  z undo  O oplog  p push  P PR  L land  ? help"

local function dock_view(state: State): Node
	local model = state.model
	local status: { Span | string } = {}
	if model then
		local branches = 0
		for _, s in model.stacks do
			branches += #s.branches
		end
		table.insert(status, ui.span(string.format("%d stacks · %d branches · %d uncommitted", #model.stacks, branches, #model.unassigned), "strong"))
		if model.behind > 0 then
			table.insert(status, ui.span(string.format("  %d behind upstream", model.behind), "warning"))
		end
	end
	if state.busy then
		table.insert(status, ui.span("  " .. state.busy, "accent"))
	elseif state.loading then
		table.insert(status, ui.span("  refreshing…", "muted"))
	elseif state.fetched then
		table.insert(status, ui.span("  updated " .. os.date("%H:%M:%S", state.fetched), "muted"))
	end
	local lines: { Node } = { ui.text(status) }
	if state.notice then
		table.insert(lines, ui.text({ ui.span(state.notice.text, state.notice.tone) }))
	elseif state.problem and model then
		table.insert(lines, ui.text({ ui.span(state.problem, "warning") }))
	end
	table.insert(lines, ui.text({ ui.span(KEYS_HELP, "dim") }))
	return ui.col({ ui.lines(lines) })
end

local function move_to(state: State, i: number)
	local row = state.rows[math.clamp(i, 1, math.max(1, #state.rows))]
	if row then
		state.cursor = row.key
	end
end

local function move_lane(state: State, delta: number)
	local row = selected(state)
	local lane = (if row then row.lane else 1) + delta
	while state.lanes[lane] ~= nil do
		local first = state.lanes[lane][1]
		if first then
			state.cursor = first.key
			return
		end
		lane += delta
	end
end

-- Actions. Every write is one `but` command, run in the background; one at
-- a time per block. Destructive ones confirm first, showing the command.

local MUTATE_TIMEOUT_MS = 60 * 1000
local NETWORK_TIMEOUT_MS = 120 * 1000

local function notify(state: State, tone: string, text: string)
	state.notice = { tone = tone, text = text }
end

-- POSIX single quotes when an argument is not a plain token. Lua %q is not
-- paste-safe: $ and backticks still expand, and `;` can stay unquoted.
local function command_line(args: { string }): string
	local parts = { "but" }
	for _, a in args do
		if string.match(a, "^[%w@%%+=:,./-]+$") then
			table.insert(parts, a)
		else
			table.insert(parts, "'" .. (string.gsub(a, "'", "'\\''")) .. "'")
		end
	end
	return table.concat(parts, " ")
end

-- Runs `but <args> --json`; on success toasts `done`, clears the marks and
-- re-reads the workspace.
local function mutate(state: State, label: string, args: { string }, timeout_ms: number, done: string)
	if state.busy then
		return
	end
	local argv = table.clone(args)
	table.insert(argv, "--json")
	state.busy = label
	state.notice = nil
	local err = gb.run(state.root, argv, timeout_ms, function(r: gb.Result)
		if running[state.cx.pane] ~= state then
			return
		end
		state.busy = nil
		if r.ok then
			notify(state, "success", done)
			state.cx:toast("success", done, command_line(args))
			table.clear(state.marked)
		else
			local why = r.err or "failed"
			notify(state, "error", command_line(args) .. ": " .. why)
			state.cx:toast("error", (string.gsub(label, "…$", "")) .. " failed", string.match(why, "^[^\n]*"))
		end
		refresh(state)
		state.cx:render()
	end)
	if err then
		state.busy = nil
		notify(state, "error", err)
	end
end

-- Runs a read (`--json` included in `args`) for an action that needs data first.
-- Escape bumps `state.reads` while `busy`; this callback is dropped so it
-- cannot open a sheet or take a fast path after cancel. `fail` is the closed
-- path when `but` itself fails (callers that omit it just notify).
local function read(state: State, label: string, args: { string }, use: (data: any) -> (), fail: ((string) -> ())?)
	if state.busy then
		return
	end
	state.busy = label
	local token = state.reads
	local err = gb.run(state.root, args, READ_TIMEOUT_MS, function(r: gb.Result)
		if not alive(state) then
			return
		end
		state.busy = nil
		if token ~= state.reads then
			state.cx:render()
			return
		end
		if r.ok then
			use(r.data)
		elseif fail then
			fail(r.err or "failed")
		else
			notify(state, "error", command_line(args) .. ": " .. (r.err or "failed"))
		end
		state.cx:render()
	end)
	if err then
		state.busy = nil
		if fail then
			fail(err)
		else
			notify(state, "error", err)
		end
	end
end

local function prompt(state: State, title: string, initial: string, done: (string) -> ())
	state.sheet = { kind = "prompt", title = title, text = initial, done = done }
end

local function confirm(state: State, title: string, body: { string }, args: { string }, danger: boolean, yes: () -> ())
	state.sheet = {
		kind = "confirm",
		title = title,
		body = body,
		command = command_line(args),
		danger = danger,
		done = function(_)
			yes()
		end,
	}
end

local function pick(state: State, title: string, options: { Option }, done: (string) -> ())
	state.sheet = { kind = "pick", title = title, options = options, index = 1, done = done }
end

local NEW_BRANCH = "\0new"

-- Applied branches that `-b` can name (anonymous segments can't be targeted).
local function branch_options(state: State, with_new: boolean): { Option }
	local out: { Option } = {}
	local model = state.model
	if model then
		for i, stack in model.stacks do
			for _, b in stack.branches do
				if b.name ~= "" then
					table.insert(out, { label = b.name, value = b.name, detail = "lane " .. (i + 1) })
				end
			end
		end
	end
	if with_new then
		table.insert(out, { label = "New branch…", value = NEW_BRANCH })
	end
	return out
end

-- The branch a row belongs to: its own for branch, commit and committed
-- file rows, the top branch of its lane for an assigned file.
local function branch_of(state: State, row: Row?): string?
	if row == nil then
		return nil
	end
	if row.kind == "branch" then
		return row.id
	elseif row.branch and row.branch ~= "" then
		return row.branch
	end
	local model = state.model
	local stack = if model and row.lane > 1 then model.stacks[row.lane - 1] else nil
	return if stack and stack.branches[1] then stack.branches[1].name else nil
end

local function apply_status(state: State, data: any): gb.Model?
	local model = gb.model(data)
	if model == nil then
		return nil
	end
	state.problem = nil
	state.model = model
	state.seen = tern.json.encode(data)
	state.fetched = os.time()
	build_rows(state)
	return model
end

local function has_marks(state: State): boolean
	for _, on in state.marked do
		if on then
			return true
		end
	end
	return false
end

-- `but` interprets colons in paths as selector separators. Callers refuse
-- those names instead of risking a different file or hunk.
local function file_arg(path: string): string
	return "zz:" .. path
end

-- Marked paths, else `picked` (the file selected before the fresh read).
-- nil ids mean every uncommitted change, and only when nothing was marked
-- and no file was picked. The third value refuses the action: a chosen
-- path is no longer uncommitted, so do not fall back to all files.
local function resolve_files(state: State, picked: string?, wanted: { [string]: boolean }): ({ string }?, string, string?)
	local any = false
	for path, on in wanted do
		if on then
			if string.find(path, ":", 1, true) then
				return nil, "", "Cannot safely target a file containing ':': " .. path .. ". Nothing was modified."
			end
			any = true
		end
	end
	if any then
		local ids: { string } = {}
		local seen: { [string]: boolean } = {}
		local stale: { string } = {}
		for _, row in state.rows do
			if row.kind == "file" and row.path and wanted[row.path] and not seen[row.path] then
				table.insert(ids, file_arg(row.path))
				seen[row.path] = true
			end
		end
		for path, _ in wanted do
			if not seen[path] then
				table.insert(stale, path)
				state.marked[path] = nil
			end
		end
		if #stale > 0 then
			local noun = if #stale == 1 then "Marked file no longer uncommitted: " else "Marked files no longer uncommitted: "
			return nil, "", noun .. table.concat(stale, ", ")
		end
		return ids, #ids .. (if #ids == 1 then " file" else " files"), nil
	end
	if picked then
		if string.find(picked, ":", 1, true) then
			return nil, "", "Cannot safely target a file containing ':': " .. picked .. ". Nothing was modified."
		end
		for _, row in state.rows do
			if row.kind == "file" and row.path == picked then
				return { file_arg(picked) }, picked, nil
			end
		end
		return nil, "", "Selected file no longer uncommitted: " .. picked
	end
	return nil, "all uncommitted changes", nil
end

-- Re-reads status before acting on specific files, so a poll that has not
-- landed yet cannot hide a mark that no longer matches.
local function fresh_files(state: State, picked: string?, use: ({ string }?, string) -> ())
	local wanted = table.clone(state.marked)
	state.reads += 1
	read(state, "Checking changes…", { "status", "-f", "--json" }, function(data: any)
		if apply_status(state, data) == nil then
			notify(state, "error", "but status printed something other than a workspace")
			return
		end
		local ids, what, stale = resolve_files(state, picked, wanted)
		if stale ~= nil then
			notify(state, "warning", stale)
			return
		end
		use(ids, what)
	end)
end

local function with_branch(state: State, title: string, with_new: boolean, done: (string) -> ())
	local options = branch_options(state, with_new)
	if #options == 0 then
		notify(state, "warning", "No named branch is applied. Press n to create one.")
		return
	end
	pick(state, title, options, function(value: string)
		if value == NEW_BRANCH then
			prompt(state, "New branch name", "", done)
		else
			done(value)
		end
	end)
end

local function append(list: { string }, more: { string }?): { string }
	local out = table.clone(list)
	for _, v in more or {} do
		table.insert(out, v)
	end
	return out
end

-- Status lists a stack's branches top-first. Rewriting the branch at index
-- i rebases every branch above it (1..i-1). Rename does not.
local function span_from(branches: { gb.Branch }, index: number, above: boolean): { gb.Branch }
	local out: { gb.Branch } = {}
	local from = if above then 1 else index
	for j = from, index do
		table.insert(out, branches[j])
	end
	return out
end

local function branch_span(model: gb.Model, name: string, above: boolean): { gb.Branch }?
	if name == "" then
		return nil
	end
	for _, stack in model.stacks do
		for i, b in stack.branches do
			if b.name == name then
				return span_from(stack.branches, i, above)
			end
		end
	end
	return nil
end

local function name_applied(model: gb.Model, name: string): boolean
	return branch_span(model, name, false) ~= nil
end

local function commit_span(model: gb.Model, id: string, above: boolean): { gb.Branch }?
	if id == "" then
		return nil
	end
	for _, stack in model.stacks do
		for i, b in stack.branches do
			for _, c in b.commits do
				if c.sha == id or c.changeId == id then
					return span_from(stack.branches, i, above)
				end
			end
		end
	end
	return nil
end

-- Names a rewrite would force-push. A missing target is included so a
-- stale or failed lookup cannot take the fast path.
local function pushed_labels(model: gb.Model, names: { string }, ids: { string }, above: boolean): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(label: string)
		if not seen[label] then
			seen[label] = true
			table.insert(out, label)
		end
	end
	local function consider(span: { gb.Branch }?, missing: string)
		if span == nil then
			add(missing)
			return
		end
		for _, b in span do
			if b.status ~= "completelyUnpushed" then
				add(if b.name ~= "" then b.name else gb.label(b))
			end
		end
	end
	for _, name in names do
		if name ~= "" then
			consider(branch_span(model, name, above), name)
		end
	end
	for _, id in ids do
		if id ~= "" then
			consider(commit_span(model, id, above), "a target commit")
		end
	end
	return out
end

local function force_line(labels: { string }, rename: boolean): string
	local who = table.concat(labels, ", ")
	local be = if #labels == 1 then " is" else " are"
	if rename then
		return who .. be .. " already pushed. The remote branch and any PR keep the old name."
	end
	return who .. be .. " already pushed and will need a force push."
end

local UNREAD = "Push state could not be read, so this is treated as already pushed and will need a force push."

local function warn_line(labels: { string }, unread: boolean, rename: boolean): string?
	if unread then
		return UNREAD
	end
	if #labels == 0 then
		return nil
	end
	return force_line(labels, rename)
end

-- Re-reads status immediately before the push decision. The mutation still
-- uses the captured changeId / branch name / zz: path, not a new selection.
-- The bump drops an older refresh. Escape cancellation lives in `read`.
local function fresh_labels(state: State, names: { string }, ids: { string }, above: boolean, use: ({ string }, boolean) -> ())
	state.reads += 1
	read(state, "Checking push state…", { "status", "-f", "--json" }, function(data: any)
		local model = gb.model(data)
		if model == nil then
			use({}, true)
			return
		end
		use(pushed_labels(model, names, ids, above), false)
	end)
end

-- Unpushed: run `go`. Pushed, missing, or unreadable: danger confirm, then `go`.
-- `rename` checks only that branch; other rewrites also check branches stacked above.
local function guard_rewrite(state: State, title: string, body: { string }, names: { string }, ids: { string }, args: { string }, rename: boolean, go: () -> ())
	fresh_labels(state, names, ids, not rename, function(labels: { string }, unread: boolean)
		local line = warn_line(labels, unread, rename)
		if line == nil then
			go()
			return
		end
		local shown = table.clone(body)
		table.insert(shown, line)
		confirm(state, title, shown, args, true, go)
	end)
end

-- Confirm a rewrite. Danger comes from a fresh status read, not the model
-- frozen while the picker was open. Enter on a non-danger confirm re-reads
-- again before mutating, so a push during the sheet cannot slip through.
local function confirm_rewrite(state: State, title: string, body: { string }, names: { string }, ids: { string }, args: { string }, go: () -> ())
	fresh_labels(state, names, ids, true, function(labels: { string }, unread: boolean)
		local line = warn_line(labels, unread, false)
		if line == nil then
			confirm(state, title, body, args, false, function()
				guard_rewrite(state, title, body, names, ids, args, false, go)
			end)
			return
		end
		local shown = table.clone(body)
		table.insert(shown, line)
		confirm(state, title, shown, args, true, go)
	end)
end



local function action_commit(state: State)
	local marked = has_marks(state)
	local picked: string? = nil
	if not marked then
		local row = selected(state)
		if row and row.kind == "file" then
			picked = row.path
		end
	end
	local function start(ids: { string }?, what: string)
		local any = false
		for _, row in state.rows do
			any = any or row.kind == "file"
		end
		if not any then
			notify(state, "info", "Nothing to commit.")
			return
		end
		with_branch(state, "Commit " .. what .. " to", true, function(branch: string)
			prompt(state, "Commit message for " .. branch, "", function(message: string)
				if message == "" then
					notify(state, "warning", "Commit cancelled: empty message")
					return
				end
				local args = append({ "commit", "-b", branch, "-m", message }, ids)
				local function go()
					mutate(state, "Committing…", args, MUTATE_TIMEOUT_MS, "Committed " .. what .. " to " .. branch)
				end
				local title = "Commit onto " .. branch
				local body = {
					"Creates a commit on " .. branch .. ". Branches stacked above it are rebased.",
				}
				local function guard()
					guard_rewrite(state, title, body, { branch }, {}, args, false, go)
				end
				-- The loaded model can miss a branch created while the prompt was open.
				-- A failed read does not take the no-confirm path.
				read(state, "Checking push state…", { "status", "-f", "--json" }, function(data: any)
					local model = gb.model(data)
					if model == nil or name_applied(model, branch) then
						guard()
						return
					end
					go()
				end, function()
					guard()
				end)
			end)
		end)
	end
	if marked or picked ~= nil then
		fresh_files(state, picked, start)
	else
		start(nil, "all uncommitted changes")
	end
end

-- Moves the selected change to a branch. `but` 0.22 has no command that
-- only assigns an uncommitted file (`rub` is retired), so an uncommitted
-- file is amended into the branch's tip commit, or committed when the
-- branch has none; committed files and commits use `but move`.
local function action_move(state: State)
	local row = selected(state)
	if row == nil or row.kind == "branch" then
		notify(state, "warning", "Select a file or commit to move.")
		return
	end
	if row.kind == "file" then
		local picked = if has_marks(state) then nil else row.path
		fresh_files(state, picked, function(ids: { string }?, what: string)
			if ids == nil then
				notify(state, "warning", "Select a file to move.")
				return
			end
			with_branch(state, "Move " .. what .. " to", false, function(branch: string)
				local empty = true
				for _, stack in (if state.model then state.model.stacks else {}) do
					for _, b in stack.branches do
						if b.name == branch and #b.commits > 0 then
							empty = false
						end
					end
				end
				if empty then
					prompt(state, branch .. " has no commits yet: message for a new commit", "", function(message: string)
						if message ~= "" then
							local args = append({ "commit", "-b", branch, "-m", message }, ids)
							guard_rewrite(state, "Commit onto " .. branch, {
								"Creates a commit on " .. branch .. ". Branches stacked above it are rebased.",
							}, { branch }, {}, args, false, function()
								mutate(state, "Committing…", args, MUTATE_TIMEOUT_MS, "Moved " .. what .. " to " .. branch)
							end)
						end
					end)
					return
				end
				local args = append({ "amend", "-t", branch }, ids)
				confirm_rewrite(state, "Move " .. what .. " into " .. branch, {
					"Amends the change into the newest commit on " .. branch .. ", rewriting that commit.",
					"but 0.22 has no way to assign an uncommitted change without committing it.",
				}, { branch }, {}, args, function()
					mutate(state, "Amending…", args, MUTATE_TIMEOUT_MS, "Moved " .. what .. " into " .. branch)
				end)
			end)
		end)
		return
	end
	if row.kind == "cfile" and row.path and string.find(row.path, ":", 1, true) then
		notify(state, "warning", "Cannot safely target a file containing ':': " .. row.path .. ". Nothing was modified.")
		return
	end
	local cid = row.changeId
	local arg = if cid and cid ~= "" then (if row.kind == "cfile" and row.path then cid .. ":" .. row.path else cid) else nil
	if arg == nil then
		notify(state, "warning", "That commit has no stable id. Nothing was modified.")
		return
	end
	local what = if row.kind == "commit" then "commit " .. row.id .. " " .. row.label else row.label .. " (" .. row.id .. ")"
	local source = row.branch or ""
	with_branch(state, "Move " .. what .. " to", false, function(branch: string)
		local args = { "move", arg, "-b", branch }
		local names = { branch }
		if source ~= "" then
			table.insert(names, source)
		end
		confirm_rewrite(state, "Move " .. what .. " to " .. branch, {
			"Rewrites both branches' history" .. (if row.kind == "cfile" then "; the file becomes a new commit on " .. branch .. "." else "."),
		}, names, { cid :: string }, args, function()
			mutate(state, "Moving…", args, MUTATE_TIMEOUT_MS, "Moved " .. what .. " to " .. branch)
		end)
	end)
end

-- Commit ids and file paths the dry-run would touch. JSON so a path
-- containing a newline cannot collide with another row.
local function absorb_sig(plan: any): ({ string }, { string }, string)
	local body: { string } = {}
	local ids: { string } = {}
	local rows: { { any } } = {}
	for _, c in (if type(plan) == "table" and type(plan.commits) == "table" then plan.commits else {}) do
		local files: { string } = {}
		for _, f in (if type(c.files) == "table" then c.files else {}) do
			table.insert(files, tostring(f.path))
		end
		local id = tostring(c.commit_id or "")
		local sorted = table.clone(files)
		table.sort(sorted)
		table.insert(rows, { id, sorted })
		table.insert(ids, id)
		table.insert(body, string.format("→ %s  %s  (%s)", string.sub(id, 1, 7), tostring(c.commit_summary or ""), tostring(c.reason_description or c.reason or "")))
		table.insert(body, "    " .. table.concat(files, ", "))
	end
	table.sort(rows, function(a, b)
		return a[1] < b[1]
	end)
	return body, ids, tern.json.encode(rows)
end

local function action_absorb(state: State)
	local row = selected(state)
	if row and row.kind == "file" and row.path and string.find(row.path, ":", 1, true) then
		notify(state, "warning", "Cannot safely target a file containing ':': " .. row.path .. ". Nothing was modified.")
		return
	end
	local source = if row and row.kind == "file" and row.path then file_arg(row.path) else nil
	local what = if row and row.kind == "file" then row.label else "all uncommitted changes"
	local args = { "absorb" }
	if source then
		table.insert(args, source)
	end
	local dry = append(args, { "--dry-run", "--json" })
	local function present(plan: any)
		local body, ids, sig = absorb_sig(plan)
		if #body == 0 then
			notify(state, "info", "Nothing to absorb.")
			return
		end
		confirm_rewrite(state, "Absorb " .. what, body, {}, ids, args, function()
			read(state, "Rechecking absorb…", dry, function(again: any)
				local next_body, _, next_sig = absorb_sig(again)
				if next_sig ~= sig then
					if #next_body == 0 then
						notify(state, "warning", "Absorb plan changed: nothing left to absorb. Nothing was modified.")
						return
					end
					notify(state, "warning", "Absorb plan changed. Nothing was modified.")
					present(again)
					return
				end
				mutate(state, "Absorbing…", args, MUTATE_TIMEOUT_MS, "Absorbed " .. what)
			end)
		end)
	end
	read(state, "Planning absorb…", dry, present)
end

local function action_reword(state: State)
	local row = selected(state)
	if row and row.kind == "commit" then
		local arg = row.changeId
		if arg == nil or arg == "" then
			notify(state, "warning", "That commit has no stable id. Nothing was modified.")
			return
		end
		prompt(state, "Reword " .. row.id, row.message or row.label, function(message: string)
			if message ~= "" and message ~= row.message then
				local args = { "reword", arg, "-m", message }
				guard_rewrite(state, "Reword " .. row.id, {}, {}, { arg }, args, false, function()
					mutate(state, "Rewording…", args, MUTATE_TIMEOUT_MS, "Reworded " .. row.id)
				end)
			end
		end)
	elseif row and row.kind == "branch" and row.branch ~= "" then
		prompt(state, "Rename branch " .. row.id, row.id, function(name: string)
			if name ~= "" and name ~= row.id then
				local args = { "reword", row.id, "-m", name }
				guard_rewrite(state, "Rename " .. row.id, {}, { row.id }, {}, args, true, function()
					mutate(state, "Renaming…", args, MUTATE_TIMEOUT_MS, "Renamed " .. row.id .. " to " .. name)
				end)
			end
		end)
	else
		notify(state, "warning", "Select a commit to reword or a branch to rename.")
	end
end

local function action_new_branch(state: State, stacked: boolean)
	local above = if stacked then branch_of(state, selected(state)) else nil
	if stacked and above == nil then
		notify(state, "warning", "Select a branch to stack the new one on.")
		return
	end
	prompt(state, if above then "New branch stacked on " .. above else "New parallel branch", "", function(name: string)
		if name == "" then
			return
		end
		local args = { "branch", "new", name }
		if above then
			table.insert(args, "-A")
			table.insert(args, above)
		end
		mutate(state, "Creating branch…", args, MUTATE_TIMEOUT_MS, "Created " .. name)
	end)
end

local function same_ids(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, v in a do
		if v ~= b[i] then
			return false
		end
	end
	return true
end

local function stack_change_ids(stack: gb.Stack): { string }
	local out: { string } = {}
	for _, b in stack.branches do
		for _, c in b.commits do
			table.insert(out, c.changeId)
		end
	end
	return out
end

-- `id` is a snapshot CLI id (anonymous branch or stack). `but` has no
-- stable handle for those, so re-read status and abort if it now labels
-- different commits.
local function guard_cli(state: State, id: string, commits: { string }, go: () -> ())
	read(state, "Checking target…", { "status", "-f", "--json" }, function(data: any)
		local model = gb.model(data)
		if model == nil then
			notify(state, "error", "but status printed something other than a workspace")
			return
		end
		for _, stack in model.stacks do
			if stack.id == id then
				if same_ids(stack_change_ids(stack), commits) then
					go()
				else
					notify(state, "warning", "That stack changed. Nothing was modified.")
				end
				return
			end
			for _, b in stack.branches do
				if b.id == id then
					local now: { string } = {}
					for _, c in b.commits do
						table.insert(now, c.changeId)
					end
					if same_ids(now, commits) then
						go()
					else
						notify(state, "warning", "That branch changed. Nothing was modified.")
					end
					return
				end
			end
		end
		notify(state, "warning", "That target changed. Nothing was modified.")
	end)
end

local function action_unapply(state: State)
	local row = selected(state)
	local model = state.model
	if row == nil or row.lane == 1 or model == nil then
		notify(state, "warning", "Select a branch lane to unapply.")
		return
	end
	local stack = model.stacks[row.lane - 1]
	local target = branch_of(state, row) or stack.id
	if target == "" then
		target = stack.id
	end
	local named = false
	for _, b in stack.branches do
		if b.name ~= "" and b.name == target then
			named = true
		end
	end
	local watched: { string }? = nil
	if not named then
		if target == stack.id then
			watched = stack_change_ids(stack)
		else
			for _, b in stack.branches do
				if b.id == target then
					local ids: { string } = {}
					for _, c in b.commits do
						table.insert(ids, c.changeId)
					end
					watched = ids
				end
			end
		end
	end
	local args = { "unapply", target }
	confirm(state, "Unapply " .. target, {
		"Removes the whole stack (" .. #stack.branches .. " branch" .. (if #stack.branches == 1 then "" else "es") .. ") from the working directory.",
		"Its commits stay on the branch; press a to apply it again.",
	}, args, true, function()
		local function go()
			mutate(state, "Unapplying…", args, MUTATE_TIMEOUT_MS, "Unapplied " .. target)
		end
		if watched then
			guard_cli(state, target, watched, go)
		else
			go()
		end
	end)
end

local function action_apply(state: State)
	read(state, "Listing branches…", { "branch", "list", "--local", "--json" }, function(data: any)
		local options: { Option } = {}
		for _, b in (if type(data) == "table" and type(data.branches) == "table" then data.branches else {}) do
			if type(b.name) == "string" then
				local ahead = if type(b.commitsAhead) == "number" then b.commitsAhead .. " ahead" else nil
				table.insert(options, { label = b.name, value = b.name, detail = ahead })
			end
		end
		if #options == 0 then
			notify(state, "info", "No unapplied local branches.")
			return
		end
		pick(state, "Apply branch", options, function(name: string)
			mutate(state, "Applying…", { "apply", name }, MUTATE_TIMEOUT_MS, "Applied " .. name)
		end)
	end)
end

local function op_text(e: any): (string, string)
	local d = if type(e) == "table" and type(e.details) == "table" then e.details else {}
	local when = if type(e.createdAt) == "number" then os.date("%m-%d %H:%M:%S", e.createdAt // 1000) else ""
	local title = tostring(d.body or d.title or d.operation or "?")
	return when, title
end

local function action_undo(state: State)
	read(state, "Reading oplog…", { "oplog", "list", "--json" }, function(data: any)
		local last = if type(data) == "table" then data[1] else nil
		if type(last) ~= "table" or type(last.id) ~= "string" then
			notify(state, "info", "Nothing to undo.")
			return
		end
		local id = last.id
		local when, title = op_text(last)
		confirm(state, "Undo the last operation", { title .. "  (" .. when .. ")" }, { "undo" }, true, function()
			-- `but undo` always reverts the current head. Restoring this
			-- snapshot instead would also revert anything that landed after it.
			read(state, "Checking oplog…", { "oplog", "list", "--json" }, function(fresh: any)
				local head = if type(fresh) == "table" then fresh[1] else nil
				if type(head) ~= "table" or head.id ~= id then
					notify(state, "warning", "A newer operation landed. Nothing was modified.")
					refresh(state)
					return
				end
				mutate(state, "Undoing…", { "undo" }, MUTATE_TIMEOUT_MS, "Undid " .. title)
			end)
		end)
	end)
end

local function action_oplog(state: State)
	read(state, "Reading oplog…", { "oplog", "list", "--json" }, function(data: any)
		local options: { Option } = {}
		for _, e in (if type(data) == "table" then data else {}) do
			if type(e.id) == "string" then
				local when, title = op_text(e)
				table.insert(options, { label = title, value = e.id, detail = string.sub(e.id, 1, 7) .. "  " .. when })
			end
		end
		if #options == 0 then
			notify(state, "info", "The oplog is empty.")
			return
		end
		pick(state, "Restore the workspace to before…", options, function(sha: string)
			local label = sha
			for _, o in options do
				if o.value == sha then
					label = o.label
				end
			end
			local args = { "oplog", "restore", sha }
			confirm(state, "Restore to before: " .. label, {
				"Branches, commits and uncommitted changes go back to the snapshot " .. string.sub(sha, 1, 7) .. ".",
				"The restore is itself recorded: z undoes it.",
			}, args, true, function()
				mutate(state, "Restoring…", args, MUTATE_TIMEOUT_MS, "Restored to " .. string.sub(sha, 1, 7))
			end)
		end)
	end)
end

-- `but push <branch> --dry-run` only reports that branch (but 0.22.3). The
-- real push also pushes every branch below it, so the check is untargeted
-- and then filtered to this branch and those below it. The span comes from
-- a fresh status read (the block model can be a poll behind; status lists a
-- stack top-first). A branch omitted from the dry-run has nothing to push.
-- A missing field, an unnamed branch we cannot match, a missing branch, or
-- a failed read is a force-push.
local function names_at_and_below(model: gb.Model, name: string): { string }?
	for _, stack in model.stacks do
		for i, b in stack.branches do
			if b.name == name then
				local out: { string } = {}
				for j = i, #stack.branches do
					local below = stack.branches[j]
					if below.name == "" then
						return nil
					end
					table.insert(out, below.name)
				end
				return out
			end
		end
	end
	return nil
end

local function force_required(data: any, names: { string }): boolean
	if type(data) ~= "table" or type(data.branches) ~= "table" then
		return true
	end
	local by_name: { [string]: any } = {}
	for _, b in data.branches do
		if type(b) == "table" and type(b.branchName) == "string" then
			by_name[b.branchName] = b
		end
	end
	for _, name in names do
		local b = by_name[name]
		if b ~= nil and (type(b.requiresForce) ~= "boolean" or b.requiresForce) then
			return true
		end
	end
	return false
end

local function confirm_publish(state: State, title: string, body: { string }, args: { string }, branch: string, label: string, done: string)
	local function show(force: boolean)
		local shown = table.clone(body)
		if force then
			table.insert(shown, "This will force-push.")
		end
		confirm(state, title, shown, args, force, function()
			mutate(state, label, args, NETWORK_TIMEOUT_MS, done)
		end)
	end
	read(state, "Checking push…", { "status", "-f", "--json" }, function(status: any)
		local model = gb.model(status)
		local names = if model then names_at_and_below(model, branch) else nil
		if names == nil then
			show(true)
			return
		end
		read(state, "Checking push…", { "push", "--dry-run", "--json" }, function(data: any)
			show(force_required(data, names :: { string }))
		end, function()
			show(true)
		end)
	end, function()
		show(true)
	end)
end

-- Push, PR and land act on the selected branch (or its lane's top branch).
local function remote_action(state: State, kind: string)
	local branch = branch_of(state, selected(state))
	if branch == nil or branch == "" then
		notify(state, "warning", "Select a named branch.")
		return
	end
	if kind == "push" then
		confirm_publish(state, "Push " .. branch, { "Pushes " .. branch .. " and the branches below it in its stack to the remote." }, { "push", branch }, branch, "Pushing…", "Pushed " .. branch)
	elseif kind == "pr" then
		confirm_publish(state, "Open a pull request for " .. branch, {
			"Pushes the branch (and those below it), then opens the review on the forge.",
			"Title and description come from the commits (-t).",
		}, { "pr", "new", branch, "-t" }, branch, "Opening PR…", "Opened a PR for " .. branch)
	else
		local args = { "land", branch, "--yes" }
		confirm(state, "Land " .. branch .. " on the target branch", {
			"Updates the target branch directly, without a pull request, and pushes it.",
			"This is not easily reversible.",
		}, args, true, function()
			mutate(state, "Landing…", args, NETWORK_TIMEOUT_MS, "Landed " .. branch)
		end)
	end
end

local HELP: { { string } } = {
	{ "↑↓ / j k, ← → / h l", "move; jump between lanes" },
	{ "⏎", "open the diff of a file, commit or branch" },
	{ "space", "mark an uncommitted file (c, m act on marks)" },
	{ "c", "commit marked/selected files (or all) to a branch" },
	{ "m", "move a file or commit to another branch" },
	{ "A", "absorb the selected file (or everything), after a dry run" },
	{ "e", "reword a commit, rename a branch" },
	{ "n / N", "new parallel branch / new branch stacked on the selected one" },
	{ "a / u", "apply a branch / unapply the selected stack" },
	{ "z / O", "undo the last operation / restore from the oplog" },
	{ "p / P / L", "push / open a PR for / land the selected branch" },
	{ "r", "refresh now (it also polls every 5 s)" },
}

-- The sheet an action shows at the top of the workspace, or nil.
local function sheet_view(state: State): Node?
	local sheet = state.sheet
	if sheet == nil then
		return nil
	end
	local children: { Node } = {}
	local foot = ""
	if sheet.kind == "prompt" then
		local lines: { Node } = {}
		local text = (sheet.text or "") .. "▌"
		for line in string.gmatch(text .. "\n", "(.-)\n") do
			table.insert(lines, ui.text({ ui.span(line, "mono") }))
		end
		table.insert(children, ui.lines(lines))
		foot = "⏎ ok  ⇧⏎ new line  esc cancel"
	elseif sheet.kind == "confirm" then
		for _, line in sheet.body or {} do
			table.insert(children, ui.text({ ui.span(line, "") }))
		end
		table.insert(children, ui.code(sheet.command or "", "sh"))
		foot = "y confirm  n/esc cancel"
	elseif sheet.kind == "pick" then
		local items: { Item } = {}
		for i, o in sheet.options or {} do
			table.insert(items, { label = { ui.span(if i <= 9 then i .. "  " else "   ", "muted num"), o.label }, value = o.detail })
		end
		local list = ui.list(items)
		local kids = list.c or {}
		for i in sheet.options or {} do
			local p: { [string]: any } = kids[i].p or {}
			p.key = "o" .. i
			kids[i].p = p
		end
		local lp: { [string]: any } = list.p or {}
		lp.key = "opts"
		lp.selected = "main.sheet.opts.o" .. (sheet.index or 1)
		list.p = lp
		table.insert(children, list)
		foot = "↑↓ choose  ⏎ ok  1-9 pick  esc cancel"
	else
		local rows: { { Cell } } = {}
		for _, h in HELP do
			table.insert(rows, { ui.span(h[1], "mono accent"), h[2] })
		end
		table.insert(children, ui.table({ { id = "key", head = "Key" }, { id = "does", head = "Does", grow = 1 } }, rows))
		foot = "esc close"
	end
	table.insert(children, ui.text({ ui.span(foot, "dim") }))
	local card = ui.card({ ui.span(sheet.title, "strong") }, children)
	local p: { [string]: any } = card.p or {}
	p.key = "sheet"
	p.tone = if sheet.danger then "error" elseif sheet.kind == "confirm" then "warning" else "accent"
	card.p = p
	return card
end

-- Closes the sheet, then runs its continuation (which may open another).
-- Polling resumes once no sheet and no read/mutation is in flight.
local function finish_sheet(state: State, value: string?)
	local sheet = state.sheet
	state.sheet = nil
	if sheet and value ~= nil and sheet.done then
		sheet.done(value)
	end
	if state.sheet == nil and state.busy == nil then
		refresh(state)
	end
end

local function sheet_key(state: State, key: Key)
	local sheet = state.sheet :: Sheet
	if key.name == "escape" then
		finish_sheet(state, nil)
		return
	end
	-- A paste is text, not a keypress: confirm and pick must ignore it.
	-- Those sheets also ignore shift/ctrl/alt/meta. A prompt still takes paste and shift+enter.
	local chord = key.ctrl or key.alt or key.meta
	if sheet.kind ~= "prompt" and (chord or key.shift or key.name == "paste") then
		return
	end
	if chord and key.name ~= "paste" then
		return
	end
	local k = key.text or key.name
	if sheet.kind == "prompt" then
		local text = sheet.text or ""
		if key.name == "enter" and key.shift then
			sheet.text = text .. "\n"
		elseif key.name == "enter" then
			finish_sheet(state, (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")))
		elseif key.name == "backspace" then
			local last = utf8.offset(text, -1)
			sheet.text = if last then string.sub(text, 1, last - 1) else ""
		elseif key.name == "paste" or key.text then
			sheet.text = text .. (key.text or "")
		end
	elseif sheet.kind == "confirm" then
		-- Enter confirms only what is easy to take back.
		if k == "y" or k == "Y" or (key.name == "enter" and not sheet.danger) then
			finish_sheet(state, "yes")
		elseif k == "n" or k == "N" then
			finish_sheet(state, nil)
		end
	elseif sheet.kind == "pick" then
		local options = sheet.options or {}
		local i = sheet.index or 1
		local n = tonumber(k)
		if key.name == "down" or k == "j" then
			sheet.index = math.min(#options, i + 1)
		elseif key.name == "up" or k == "k" then
			sheet.index = math.max(1, i - 1)
		elseif key.name == "enter" and options[i] then
			finish_sheet(state, options[i].value)
		elseif n and options[n] then
			finish_sheet(state, options[n].value)
		end
	end
end

local ACTIONS: { [string]: (State) -> () } = {
	c = action_commit,
	m = action_move,
	A = action_absorb,
	e = action_reword,
	n = function(state: State)
		action_new_branch(state, false)
	end,
	N = function(state: State)
		action_new_branch(state, true)
	end,
	a = action_apply,
	u = action_unapply,
	z = action_undo,
	O = action_oplog,
	p = function(state: State)
		remote_action(state, "push")
	end,
	P = function(state: State)
		remote_action(state, "pr")
	end,
	L = function(state: State)
		remote_action(state, "land")
	end,
	["?"] = function(state: State)
		state.sheet = { kind = "help", title = "GitButler keys" }
	end,
}

-- Actions reachable from outside the block (palette commands send these
-- as `action` events): the same table, by name.
local NAMED: { [string]: string } = {
	commit = "c",
	move = "m",
	absorb = "A",
	reword = "e",
	branch = "n",
	stack = "N",
	apply = "a",
	unapply = "u",
	undo = "z",
	oplog = "O",
	push = "p",
	pr = "P",
	land = "L",
	help = "?",
}

local function run_action(state: State, k: string): boolean
	local action = ACTIONS[k]
	if action == nil then
		return false
	end
	if state.busy then
		notify(state, "warning", "Wait for " .. state.busy)
	elseif state.model == nil then
		notify(state, "warning", "The workspace isn't loaded yet.")
	else
		action(state)
	end
	return true
end

tern.block.define("workspace", {
	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local previous = running[cx.pane]
		if previous and previous.timer then
			previous.timer:cancel()
		end
		local root = gb.root(args[1] or cx.cwd) or args[1] or cx.cwd or ""
		local state: State = {
			cx = cx,
			root = root,
			model = nil,
			seen = nil,
			reads = 0,
			rows = {},
			lanes = {},
			cursor = nil,
			marked = {},
			loading = false,
			fetched = nil,
			problem = if gb.root(root) then nil else "Not a GitButler workspace: " .. root,
			timer = nil,
			sheet = nil,
			busy = nil,
			notice = nil,
		}
		running[cx.pane] = state
		if state.problem == nil then
			refresh(state)
			poll(state)
		end
		return state
	end,

	title = function(state: State): string?
		return "GitButler · " .. basename(state.root)
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local model = state.model
		if model == nil then
			if state.problem then
				local card = ui.card({ ui.span("GitButler workspace unavailable", "strong") }, {
					ui.code(state.problem),
					ui.text({ ui.span("Press r to retry.", "muted") }),
				})
				local p: { [string]: any } = card.p or {}
				p.tone = "error"
				card.p = p
				return { main = ui.col({ card }) }
			end
			return { main = ui.col({ ui.progress(nil, "Reading the workspace…") }) }
		end
		local main: { Node } = {}
		local sheet = sheet_view(state)
		if sheet then
			table.insert(main, sheet)
		end
		table.insert(main, lanes_view(state, model))
		return { main = ui.col(main), dock = dock_view(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if state.sheet then
			sheet_key(state, key)
			return true
		end
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		local i = index_of(state)
		if key.name == "down" or k == "j" then
			move_to(state, i + 1)
		elseif key.name == "up" or k == "k" then
			move_to(state, i - 1)
		elseif key.name == "left" or k == "h" then
			move_lane(state, -1)
		elseif key.name == "right" or k == "l" then
			move_lane(state, 1)
		elseif key.name == "home" or k == "g" then
			move_to(state, 1)
		elseif key.name == "end" or k == "G" then
			move_to(state, #state.rows)
		elseif key.name == "enter" or k == "o" then
			open_diff(state, cx)
			return false
		elseif k == "r" then
			if state.problem and state.model == nil then
				state.problem = if gb.root(state.root) then nil else state.problem
			end
			state.notice = nil
			refresh(state)
			poll(state)
		elseif key.name == "space" then
			local row = selected(state)
			if row and row.kind == "file" and row.path then
				state.marked[row.path] = not state.marked[row.path] or nil
				move_to(state, i + 1)
			end
		elseif key.name == "escape" then
			if state.busy then
				state.reads += 1
			end
			state.notice = nil
			table.clear(state.marked)
		else
			return run_action(state, k)
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and type(ev.act) == "string" and NAMED[ev.act] then
			-- From the palette: start the action on the current selection.
			if state.sheet == nil then
				run_action(state, NAMED[ev.act])
			end
			return
		end
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local opt = string.match(ev.item, "^main%.sheet%.opts%.o(%d+)$")
			local sheet = state.sheet
			if opt and sheet and sheet.kind == "pick" then
				local n = tonumber(opt) :: number
				sheet.index = n
				if ev.ev == "activate" and sheet.options and sheet.options[n] then
					finish_sheet(state, sheet.options[n].value)
				end
				return
			end
			local key = string.match(ev.item, "%.rows%.(.+)$")
			if key then
				state.cursor = key
			end
			if ev.ev == "activate" then
				open_diff(state, cx)
			end
		end
	end,
})

-- The diff block: `but diff <id> --json` for one file, commit or branch.

type DiffState = {
	cx: BlockCx,
	root: string,
	id: string,
	label: string,
	changes: { gb.Change }?,
	problem: string?,
}

local MAX_DIFF_LINES = 5000

local function load_diff(state: DiffState)
	local err = gb.run(state.root, { "diff", state.id, "--json" }, READ_TIMEOUT_MS, function(r: gb.Result)
		if not pane_alive(state.cx.pane) then
			return
		end
		local changes = if r.ok then gb.changes(r.data) else nil
		if changes then
			state.changes, state.problem = changes, nil
		else
			state.problem = r.err or "but diff printed something other than a diff"
		end
		state.cx:render()
	end)
	if err then
		state.problem = err
	end
end

tern.block.define("diff", {
	init = function(cx: BlockCx, args: { string }, _saved: any): DiffState
		local state: DiffState = {
			cx = cx,
			root = args[1] or cx.cwd or "",
			id = args[2] or "",
			label = args[3] or args[2] or "",
			changes = nil,
			problem = nil,
		}
		load_diff(state)
		return state
	end,

	title = function(state: DiffState): string?
		return "Diff · " .. state.label
	end,

	view = function(state: DiffState, _cx: BlockCx): BlockView
		local dock = ui.col({ ui.text({ ui.span(state.id .. "  ", "mono muted"), ui.span("r reload  q close", "dim") }) })
		if state.changes == nil then
			if state.problem then
				return { main = ui.col({ ui.code(state.problem) }), dock = dock }
			end
			return { main = ui.col({ ui.progress(nil, "Reading the diff…") }) }
		end
		local nodes: { Node } = {}
		local budget = MAX_DIFF_LINES
		for i, c in state.changes :: { gb.Change } do
			local head = { ui.span(c.path, "strong"), ui.span("  " .. c.status, "muted") }
			local body: Node
			local text = c.text
			if text == nil then
				body = ui.text({ ui.span("No text diff (binary or too large).", "muted") })
			else
				local _, lines = string.gsub(text, "\n", "\n")
				if budget <= 0 then
					body = ui.overflow(lines)
				else
					budget -= lines
					body = ui.diff(text, c.path)
				end
			end
			local section = ui.section(head, { body })
			local p: { [string]: any } = section.p or {}
			p.key = "c" .. i
			p.collapsible = true
			section.p = p
			table.insert(nodes, section)
		end
		if #nodes == 0 then
			table.insert(nodes, ui.text({ ui.span("No changes.", "muted") }))
		end
		return { main = ui.col(nodes), dock = dock }
	end,

	key = function(state: DiffState, key: Key, cx: BlockCx): boolean?
		local k = key.text or key.name
		if k == "r" then
			load_diff(state)
		elseif k == "q" or key.name == "escape" then
			cx:exit(0)
		else
			return false
		end
		return true
	end,
})

