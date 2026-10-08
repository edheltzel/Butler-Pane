--!strict
-- Readers for `but`'s human output, used only by the command lenses (the
-- block and the status segment read `--json`). Pure: no `tern`, so
-- `luau check.luau` can run them. Each takes the lines a lens received
-- (escape sequences already applied) and returns nil when it can't read them.

local parse = {}

export type File = { id: string, path: string, change: string }
export type Commit = { id: string, sha: string, title: string, conflicted: boolean, upstream: boolean, files: { File } }
export type Branch = { id: string, name: string, status: string, review: string?, commits: { Commit }, upstream: number }
export type Stack = { id: string, branches: { Branch }, assigned: { File } }
export type Status = { unassigned: { File }, stacks: { Stack }, behind: number, base: string? }

-- Splits a line into its leading graph (spaces, box drawing and other
-- non-ASCII glyphs) and the text after it.
local function split_graph(line: string): (string, string)
	local i = 1
	while i <= #line do
		local b = string.byte(line, i) :: number
		if b == 32 or b >= 128 then
			i += 1
		else
			break
		end
	end
	return string.sub(line, 1, i - 1), string.sub(line, i)
end

local function has(s: string, glyph: string): boolean
	return string.find(s, glyph, 1, true) ~= nil
end

local COMMIT_DOTS = { "●", "◐", "○", "◉", "◇", "◆" }

local function is_commit(graph: string): boolean
	for _, dot in COMMIT_DOTS do
		if has(graph, dot) then
			return true
		end
	end
	return false
end

-- `id  M path`: a change line (uncommitted, assigned or committed).
local function file_of(rest: string): File?
	local id, change, path = string.match(rest, "^(%S+)%s+([MADRCTU])%s+(.+)$")
	if id and change and path then
		return { id = id, path = path, change = change }
	end
	return nil
end

-- `but status [-f] [-v]`.
function parse.status(lines: { string }): Status?
	local out: Status = { unassigned = {}, stacks = {}, behind = 0, base = nil }
	local stack: Stack? = nil
	local branch: Branch? = nil
	local commit: Commit? = nil
	local in_uncommitted = false
	local upstream = false
	local want_title = false -- `-v` prints the message on the line after the commit
	local seen = false
	for _, line in lines do
		local graph, rest = split_graph(line)
		if has(graph, "┄") then
			seen = true
			local id, tail = string.match(rest, "^(%S+)%s*(.*)$")
			if string.sub(rest, 1, 9) == "(upstream" then
				upstream = true
			elseif id == "zz" then
				in_uncommitted = true
			elseif id then
				in_uncommitted, upstream = false, false
				local name = string.match(tail or "", "^%[(.-)%]") or ""
				local b: Branch = { id = id, name = name, status = "", review = nil, commits = {}, upstream = 0 }
				if stack == nil or has(graph, "╭") then
					local s: Stack = { id = id, branches = {}, assigned = {} }
					table.insert(out.stacks, s)
					stack = s
				end
				table.insert((stack :: Stack).branches, b)
				branch, commit = b, nil
			end
			want_title = false
		elseif rest == "-" then
			upstream = false
		elseif is_commit(graph) and branch then
			local id, text = string.match(rest, "^(%S+)%s*(.*)$")
			if id then
				local sha = string.match(text or "", "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d [-+]%d+ %(sha (%x+)%)")
				local c: Commit = {
					id = id,
					sha = sha or "",
					title = if sha then "" else (text or ""),
					conflicted = has(rest, "{conflicted}"),
					upstream = upstream,
					files = {},
				}
				table.insert(branch.commits, c)
				if upstream then
					branch.upstream += 1
				end
				commit = c
				want_title = sha ~= nil
			end
		elseif has(graph, "┴") then
			out.base = string.match(rest, "^(%x+)")
			want_title = false
		else
			local f = file_of(rest)
			if f and in_uncommitted then
				table.insert(out.unassigned, f)
			elseif f and commit and string.find(f.id, ":", 1, true) then
				table.insert(commit.files, f)
			elseif f and stack and commit == nil then
				table.insert(stack.assigned, f)
			elseif want_title and commit and rest ~= "" then
				commit.title = rest
				want_title = false
			end
		end
	end
	return if seen then out else nil
end

export type Line = { sign: string, text: string }
export type DiffFile = { label: string, path: string, text: string }

-- `but diff [id]`: per file, the unified diff text `tern.ui.diff` takes.
function parse.diff(lines: { string }): { DiffFile }?
	local files: { DiffFile } = {}
	local current: { label: string, path: string, parts: { string } }? = nil
	local all: { { label: string, path: string, parts: { string } } } = {}
	for _, line in lines do
		local label, path = string.match(line, "^ (%S+) (.-) │$")
		if label and path then
			local f = { label = label, path = path, parts = { "--- a/" .. path, "+++ b/" .. path } }
			table.insert(all, f)
			current = f
		elseif current then
			if string.sub(line, 1, 2) == "@@" then
				table.insert(current.parts, line)
			else
				local body = string.match(line, "^%s*%d*%s*┊%s*%d*%s*│ ?(.*)$")
				if body then
					local sign = string.sub(body, 1, 1)
					if sign ~= "+" and sign ~= "-" then
						body = " " .. string.sub(body, 2)
					end
					table.insert(current.parts, body)
				end
			end
		end
	end
	for _, f in all do
		table.insert(files, { label = f.label, path = f.path, text = table.concat(f.parts, "\n") })
	end
	return if #files > 0 then files else nil
end

export type ShowCommit = { id: string, title: string, when: string?, author: string?, files: { File } }
export type Show = {
	kind: string, -- "commit" | "branch"
	fields: { { string } }, -- commit: Commit, Change-ID, Author, Date…
	message: string?,
	files: { File },
	branch: string?,
	commits: { ShowCommit },
}

-- `but show <commit|branch> [-v]`.
function parse.show(lines: { string }): Show?
	local out: Show = { kind = "", fields = {}, message = nil, files = {}, branch = nil, commits = {} }
	local section = ""
	local message: { string } = {}
	local commit: ShowCommit? = nil
	for _, line in lines do
		local graph, rest = split_graph(line)
		local branch = string.match(line, "^Branch: (.+)$")
		local key, value = string.match(line, "^([%w%-]+):%s+(.+)$")
		if branch and out.kind == "" then
			out.kind, out.branch = "branch", branch
		elseif out.kind == "" and key == "Commit" then
			out.kind = "commit"
			table.insert(out.fields, { key, value :: string })
			section = "head"
		elseif out.kind == "commit" and section == "head" and key and value then
			table.insert(out.fields, { key, value })
		elseif out.kind == "commit" and line == "Files changed:" then
			section = "files"
		elseif out.kind == "commit" and section == "files" then
			local change, path = string.match(rest, "^([MADRCTU])%s+(.+)$")
			if change and path then
				table.insert(out.files, { id = "", path = path, change = change })
			end
		elseif out.kind == "commit" and (section == "head" or section == "message") then
			if line == "" and section == "head" then
				section = "message"
			else
				section = "message"
				table.insert(message, line)
			end
		elseif out.kind == "branch" then
			if line == "Branch Summary:" or has(graph, "┴") then
				section = "summary"
			elseif section ~= "summary" then
				local id, title = string.match(rest, "^(%S+) (.+)$")
				local when, author = string.match(rest, "^(%d%d%d%d%-%d%d%-%d%d [%d:]+).- by (.+)$")
				local change, path = string.match(rest, "^([MADRCTU]) (%S+)")
				if when and commit then
					commit.when, commit.author = when, author
				elseif change and path and commit then
					table.insert(commit.files, { id = "", path = path, change = change })
				elseif id and title and (is_commit(graph) or (graph == "  " and rest ~= "Commits:")) then
					local c: ShowCommit = { id = id, title = title, when = nil, author = nil, files = {} }
					table.insert(out.commits, c)
					commit = c
				end
			end
		end
	end
	while #message > 0 and message[#message] == "" do
		table.remove(message)
	end
	out.message = if #message > 0 then table.concat(message, "\n") else nil
	return if out.kind ~= "" then out else nil
end

export type Op = { sha: string, when: string, kind: string, title: string }

-- `but oplog [list]`.
function parse.oplog(lines: { string }): { Op }?
	local ops: { Op } = {}
	local seen = false
	for _, line in lines do
		if line == "Operations History" then
			seen = true
		end
		local sha, when, kind, title = string.match(line, "^(%x%x%x%x%x%x%x+) (%d%d%d%d%-%d%d%-%d%d [%d:]+) %[([^%]]+)%] ?(.*)$")
		if sha and when and kind then
			table.insert(ops, { sha = sha, when = when, kind = kind, title = title or "" })
		end
	end
	return if seen or #ops > 0 then ops else nil
end

return parse
