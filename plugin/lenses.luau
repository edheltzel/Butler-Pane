--!strict
-- Command lenses, required by host.luau: `but status`, `but diff`, `but
-- show` and `but oplog` typed in a shell. With `--json` the output is
-- decoded; otherwise the human text is read by `parse` (lenses only:
-- everything else in this plugin reads JSON).

local gb = require("./gb")
local parse = require("./parse")
local ui = tern.ui
local letter = gb.letter
local STATUS_TEXT = gb.STATUS_TEXT
local changes_of = gb.changes

-- `but` asks the terminal for its colors (OSC 10/11, DA1) unless BUT_THEME
-- is set, and pages through `less`, which turns on keypad mode. Either one
-- makes Tern abort a lens capture, so shells get both preset; a value the
-- daemon inherited, or one exported in a shell rc, still wins.
tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	if tern.getenv("BUT_THEME") == nil then
		spec.env.BUT_THEME = "dark"
	end
	if tern.getenv("BUT_PAGER") == nil then
		spec.env.BUT_PAGER = "cat"
	end
	return spec
end)

type LensState = { json: boolean, lines: { string }, status: number? }

local function lens_open(run: LensRun, _cx: EffectCx): LensState
	return { json = table.find(run.args, "--json") ~= nil, lines = {}, status = nil }
end

local function lens_line(state: LensState, l: LensLine)
	table.insert(state.lines, l.text)
end

local function lens_finish(state: LensState, status: number)
	state.status = status
end

local function decoded(state: LensState): any
	local ok, data = pcall(tern.json.decode, table.concat(state.lines, "\n"))
	return if ok then data else nil
end

-- Shared by every lens: nothing while output arrives, raw output (nil) for
-- a failed command or output the lens can't read.
local function lens(build: (LensState) -> Node?): LensDef<LensState>
	return {
		open = lens_open,
		line = lens_line,
		finish = lens_finish,
		view = function(state: LensState): Node?
			if state.status == nil then
				return ui.progress(nil, "Running but…")
			end
			if state.status ~= 0 then
				return nil
			end
			return build(state)
		end,
	}
end

local function counts(stacks: { any }, unassigned: number): Node
	local branches = 0
	for _, s in stacks do
		branches += #s.branches
	end
	return ui.row({
		ui.badge(#stacks .. (if #stacks == 1 then " stack" else " stacks"), "accent"),
		ui.badge(branches .. (if branches == 1 then " branch" else " branches"), "neutral"),
		ui.badge(unassigned .. " uncommitted", if unassigned > 0 then "warning" else "muted"),
	})
end

local function file_label(f: { id: string, path: string, change: string }): Spans
	return { ui.span(f.id .. "  ", "muted mono"), ui.span(letter(f.change) .. " ", "warning mono"), f.path }
end

tern.lens.define("status", lens(function(state: LensState): Node?
	local model: any = if state.json then gb.model(decoded(state)) else parse.status(state.lines)
	if model == nil then
		return nil
	end
	local nodes: { TreeNode } = {}
	local files: { TreeNode } = {}
	for _, f in model.unassigned do
		table.insert(files, { label = file_label(f), icon = "file" })
	end
	table.insert(nodes, {
		label = { ui.span("zz  ", "muted mono"), ui.span("Uncommitted", "strong"), ui.span("  " .. #files, "muted num") },
		icon = "file",
		open = true,
		children = files,
	})
	for _, stack in model.stacks do
		local branches: { TreeNode } = {}
		for _, f in stack.assigned do
			table.insert(branches, {
				label = { ui.span("assigned  ", "accent"), ui.span(f.id .. "  ", "muted mono"), ui.span(letter(f.change) .. " ", "warning mono"), f.path },
				icon = "file",
			})
		end
		for _, b in stack.branches do
			local commits: { TreeNode } = {}
			for _, c in b.commits do
				local cfiles: { TreeNode } = {}
				for _, f in c.files do
					table.insert(cfiles, { label = file_label(f), icon = "file" })
				end
				local label: { Span | string } = { ui.span(c.id .. "  ", "muted mono"), c.title }
				if c.upstream then
					table.insert(label, 1, ui.span("upstream  ", "warning"))
				end
				if c.conflicted then
					table.insert(label, ui.span("  conflicted", "error"))
				end
				table.insert(commits, { label = label, icon = "commit", open = false, children = if #cfiles > 0 then cfiles else nil })
			end
			local status = STATUS_TEXT[b.status]
			local head: { Span | string } = { ui.span(b.id .. "  ", "muted mono"), ui.span(gb.label(b), "strong") }
			if status then
				table.insert(head, ui.span("  " .. status[1], status[2]))
			end
			table.insert(branches, { label = head, icon = "git-branch", open = true, children = commits })
		end
		local names: { string } = {}
		for _, b in stack.branches do
			table.insert(names, gb.label(b))
		end
		if #stack.branches == 1 and #stack.assigned == 0 then
			table.insert(nodes, branches[1])
		else
			table.insert(nodes, {
				label = { ui.span("Stack  ", "muted"), ui.span(table.concat(names, " ▸ "), "strong") },
				icon = "stack",
				open = true,
				children = branches,
			})
		end
	end
	local children: { Node } = { counts(model.stacks, #model.unassigned), ui.tree(nodes) }
	if model.base then
		table.insert(children, ui.text({ ui.span("common base  ", "muted"), ui.span(model.base, "mono") }))
	end
	return ui.col(children)
end))

tern.lens.define("diff", lens(function(state: LensState): Node?
	local files: { { label: string, path: string, text: string? } } = {}
	if state.json then
		for _, c in changes_of(decoded(state)) or {} do
			table.insert(files, { label = c.status, path = c.path, text = c.text })
		end
	else
		for _, f in parse.diff(state.lines) or {} do
			table.insert(files, f)
		end
	end
	if #files == 0 then
		return nil
	end
	local sections: { Node } = {}
	for i, f in files do
		local body = if f.text then ui.diff(f.text :: string, f.path) else ui.text({ ui.span("No text diff.", "muted") })
		local section = ui.section({ ui.span(f.path, "strong"), ui.span("  " .. f.label, "muted mono") }, { body })
		local p: { [string]: any } = section.p or {}
		p.key = "f" .. i
		p.collapsible = true
		section.p = p
		table.insert(sections, section)
	end
	return ui.col(sections)
end))

-- `but show --json`: a commit (`commit`, `author`, `message`, `files`) or a
-- branch (`branch`, `commits`), as `parse.show` returns them.
local function show_of_json(data: any): parse.Show?
	if type(data) ~= "table" then
		return nil
	end
	local function json_files(list: any): { parse.File }
		local out: { parse.File } = {}
		for _, f in (if type(list) == "table" then list else {}) do
			table.insert(out, { id = "", path = tostring(f.path or "?"), change = letter(tostring(f.status or "")) })
		end
		return out
	end
	if type(data.commit) == "string" then
		local author = if type(data.author) == "table" then string.format("%s <%s>", tostring(data.author.name), tostring(data.author.email)) else "?"
		return {
			kind = "commit",
			fields = { { "Commit", data.commit }, { "Change-ID", tostring(data.changeId or "") }, { "Author", author }, { "Date", tostring(data.date or "") } },
			message = if type(data.message) == "string" then data.message else nil,
			files = json_files(data.files),
			branch = nil,
			commits = {},
		}
	elseif type(data.branch) == "string" then
		local commits: { parse.ShowCommit } = {}
		for _, c in (if type(data.commits) == "table" then data.commits else {}) do
			table.insert(commits, {
				id = tostring(c.cli_id or c.short_sha or "?"),
				title = tostring(c.message or ""),
				when = if type(c.timestamp) == "number" then os.date("%Y-%m-%d %H:%M", c.timestamp) else nil,
				author = if type(c.author_name) == "string" then c.author_name else nil,
				files = json_files(c.files),
			})
		end
		return { kind = "branch", fields = {}, message = nil, files = {}, branch = data.branch, commits = commits }
	end
	return nil
end

local FILE_COLS: { Col } = { { id = "change", head = "" }, { id = "path", head = "File", grow = 1, truncate = "middle" } }

tern.lens.define("show", lens(function(state: LensState): Node?
	local show = if state.json then show_of_json(decoded(state)) else parse.show(state.lines)
	if show == nil then
		return nil
	end
	local children: { Node } = {}
	if show.kind == "commit" then
		local items: { { Spans } } = {}
		for _, kv in show.fields do
			table.insert(items, { kv[1], ui.span(kv[2], if kv[1] == "Commit" or kv[1] == "Change-ID" then "mono" else "") })
		end
		table.insert(children, ui.kv(items))
		if show.message then
			table.insert(children, ui.card({ ui.span("Message", "muted") }, { ui.code(show.message, "text") }))
		end
		local rows: { { Cell } } = {}
		for _, f in show.files do
			table.insert(rows, { ui.span(f.change, "warning mono"), f.path })
		end
		if #rows > 0 then
			table.insert(children, ui.table(FILE_COLS, rows))
		end
	else
		table.insert(children, ui.text({ ui.span("Branch  ", "muted"), ui.span(show.branch or "?", "strong") }))
		local rows: { { Cell } } = {}
		for _, c in show.commits do
			table.insert(rows, {
				ui.span(c.id, "mono muted"),
				c.title,
				ui.span(if #c.files > 0 then tostring(#c.files) else "", "num muted"),
				ui.span(c.author or "", "muted"),
				ui.span(c.when or "", "muted num"),
			})
		end
		table.insert(children, ui.table({
			{ id = "id", head = "ID" },
			{ id = "title", head = "Commit", grow = 1 },
			{ id = "files", head = "Files", align = "end", priority = -2 },
			{ id = "author", head = "Author", priority = -1 },
			{ id = "when", head = "When", align = "end", priority = -1 },
		}, rows))
	end
	return ui.col(children)
end))

local function ops_of_json(data: any): { parse.Op }?
	if type(data) ~= "table" then
		return nil
	end
	local ops: { parse.Op } = {}
	for _, e in data do
		local d = if type(e.details) == "table" then e.details else {}
		table.insert(ops, {
			sha = string.sub(tostring(e.id or ""), 1, 7),
			when = if type(e.createdAt) == "number" then os.date("%Y-%m-%d %H:%M:%S", e.createdAt // 1000) else "",
			kind = tostring(d.operation or ""),
			title = tostring(d.body or d.title or ""),
		})
	end
	return ops
end

tern.lens.define("oplog", lens(function(state: LensState): Node?
	local ops = if state.json then ops_of_json(decoded(state)) else parse.oplog(state.lines)
	if ops == nil then
		return nil
	end
	local rows: { { Cell } } = {}
	for _, op in ops do
		local undo = string.find(op.kind, "UNDO") or string.find(op.kind, "RESTORE") or string.find(op.kind, "Restore")
		table.insert(rows, {
			ui.span(op.sha, "mono"),
			ui.span(op.when, "muted num"),
			ui.span(op.kind, if undo then "warning" else "accent"),
			op.title,
		})
	end
	return ui.col({
		ui.text({ ui.span("Operations  ", "strong"), ui.span(#ops .. " entries · restore with but oplog restore <sha>", "muted") }),
		ui.table({
			{ id = "sha", head = "Snapshot" },
			{ id = "when", head = "When", priority = -1 },
			{ id = "op", head = "Operation" },
			{ id = "title", head = "Description", grow = 1 },
		}, rows),
	})
end))


return {}
