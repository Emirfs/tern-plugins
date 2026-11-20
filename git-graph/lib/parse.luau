--!strict
-- Git command lines and parsers for what they print. Pure: no Tern API, so lune tests run them directly.

local Parse = {}

local FS, RS = "\31", "\30"

export type Ref = {
	name: string,
	kind: "branch" | "remote" | "tag" | "head",
	-- The branch HEAD points at.
	current: boolean,
}
export type Commit = {
	hash: string,
	short: string,
	parents: { string },
	author: string,
	time: number,
	subject: string,
	refs: { Ref },
}
export type Status = {
	branch: string?,
	detached: boolean,
	upstream: string?,
	ahead: number,
	behind: number,
	-- Tracked files with staged or unstaged changes.
	changed: number,
	untracked: number,
	conflicts: number,
}
export type FileChange = { status: string, path: string, old: string? }
export type Detail = {
	hash: string,
	parents: { string },
	author: string,
	email: string,
	time: number,
	committer: string,
	ctime: number,
	body: string,
	files: { FileChange },
}

-- Common flags: never page, color or quote non-ASCII paths; don't take optional locks that a
-- running `git commit` in a terminal would trip over.
function Parse.git(repo: string, args: { string }): { string }
	local argv = { "git", "-C", repo, "-c", "core.quotepath=off", "-c", "color.ui=never", "--no-optional-locks" }
	table.move(args, 1, #args, #argv + 1, argv)
	return argv
end

Parse.LOG_FORMAT = table.concat({ "%H", "%P", "%an", "%at", "%s", "%D" }, "%x1f") .. "%x1e"

function Parse.log_args(remotes: boolean, skip: number, count: number): { string }
	local args = {
		"log", "--date-order", "--decorate=full", `--format={Parse.LOG_FORMAT}`,
		`--max-count={count}`, `--skip={skip}`, "--branches", "--tags", "HEAD",
	}
	if remotes then
		table.insert(args, "--remotes")
	end
	return args
end

local function split(s: string, sep: string): { string }
	local out: { string } = {}
	local start = 1
	while true do
		local i = string.find(s, sep, start, true)
		if i == nil then
			table.insert(out, string.sub(s, start))
			return out
		end
		table.insert(out, string.sub(s, start, i - 1))
		start = i + #sep
	end
end

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

--- `%D` with `--decorate=full`: `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
function Parse.refs(decoration: string): { Ref }
	local out: { Ref } = {}
	if decoration == "" then
		return out
	end
	local current: string? = nil
	for _, part in split(decoration, ", ") do
		part = trim(part)
		local target = string.match(part, "^HEAD %-> (.+)$")
		if target then
			current = target
			part = target
		end
		local tag = string.match(part, "^tag: refs/tags/(.+)$")
		local branch = string.match(part, "^refs/heads/(.+)$")
		local remote = string.match(part, "^refs/remotes/(.+)$")
		if tag then
			table.insert(out, { name = tag, kind = "tag", current = false })
		elseif branch then
			table.insert(out, { name = branch, kind = "branch", current = part == current })
		elseif remote then
			-- `origin/HEAD` only says which branch the remote calls default; it is noise in a graph.
			if not string.match(remote, "/HEAD$") then
				table.insert(out, { name = remote, kind = "remote", current = false })
			end
		elseif part == "HEAD" then
			table.insert(out, { name = "HEAD", kind = "head", current = true })
		end
	end
	-- Current branch first, then local branches, remotes, tags.
	local order = { head = 0, branch = 1, remote = 2, tag = 3 }
	table.sort(out, function(a, b)
		if a.current ~= b.current then
			return a.current
		end
		if a.kind ~= b.kind then
			return order[a.kind] < order[b.kind]
		end
		return a.name < b.name
	end)
	return out
end

function Parse.log(text: string): { Commit }
	local out: { Commit } = {}
	for _, record in split(text, RS) do
		record = string.gsub(record, "^[\r\n]+", "")
		if record ~= "" then
			local f = split(record, FS)
			if #f >= 6 and #f[1] == 40 then
				table.insert(out, {
					hash = f[1],
					short = string.sub(f[1], 1, 7),
					parents = if f[2] == "" then {} else split(f[2], " "),
					author = f[3],
					time = tonumber(f[4]) or 0,
					subject = f[5],
					refs = Parse.refs(trim(f[6])),
				})
			end
		end
	end
	return out
end

--- `git status --porcelain=v2 --branch`.
function Parse.status(text: string): Status
	local st: Status = {
		branch = nil, detached = false, upstream = nil, ahead = 0, behind = 0,
		changed = 0, untracked = 0, conflicts = 0,
	}
	for line in string.gmatch(text, "[^\r\n]+") do
		local head = string.match(line, "^# branch%.head (.+)$")
		local upstream = string.match(line, "^# branch%.upstream (.+)$")
		local ahead, behind = string.match(line, "^# branch%.ab %+(%d+) %-(%d+)$")
		if head then
			st.detached = head == "(detached)"
			st.branch = if st.detached then nil else head
		elseif upstream then
			st.upstream = upstream
		elseif ahead then
			st.ahead, st.behind = tonumber(ahead) or 0, tonumber(behind) or 0
		elseif string.match(line, "^[12] ") then
			st.changed += 1
		elseif string.match(line, "^u ") then
			st.conflicts += 1
		elseif string.match(line, "^%? ") then
			st.untracked += 1
		end
	end
	return st
end

-- Tags peeled to their commit, so an annotated tag points where the graph draws it.
Parse.REFS_FORMAT = "%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end) %(refname)"

export type RefTip = { name: string, kind: "branch" | "remote" | "tag", hash: string }

--- `for-each-ref --format=REFS_FORMAT`: branches, remotes (without `<remote>/HEAD`) and tags, each sorted.
function Parse.ref_list(text: string): { RefTip }
	local out: { RefTip } = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local hash, ref = string.match(line, "^(%x+) (%S+)$")
		if hash and ref then
			local branch = string.match(ref, "^refs/heads/(.+)$")
			local remote = string.match(ref, "^refs/remotes/(.+)$")
			local tag = string.match(ref, "^refs/tags/(.+)$")
			if branch then
				table.insert(out, { name = branch, kind = "branch", hash = hash })
			elseif remote and not string.match(remote, "/HEAD$") then
				table.insert(out, { name = remote, kind = "remote", hash = hash })
			elseif tag then
				table.insert(out, { name = tag, kind = "tag", hash = hash })
			end
		end
	end
	local order = { branch = 1, remote = 2, tag = 3 }
	table.sort(out, function(a, b)
		if a.kind ~= b.kind then
			return order[a.kind] < order[b.kind]
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	return out
end

--- What changes when anything moves: every ref and HEAD. `for-each-ref` then `rev-parse HEAD`.
function Parse.signature(refs: string, head: string): string
	return trim(head) .. "\n" .. trim(refs)
end

Parse.SHOW_FORMAT = table.concat({ "%H", "%P", "%an", "%ae", "%at", "%cn", "%ct", "%B" }, "%x1f") .. "%x1e"

function Parse.show_args(hash: string): { string }
	return { "show", "--no-patch", `--format={Parse.SHOW_FORMAT}`, hash }
end

-- Merges list what they brought in over the first parent, like a pull request does.
function Parse.files_args(hash: string): { string }
	return { "diff-tree", "-r", "-M", "--root", "--no-commit-id", "--diff-merges=first-parent", "--name-status", hash }
end

function Parse.diff_args(hash: string, file: FileChange): { string }
	local args = { "show", "--format=", "--no-color", "-M", "--diff-merges=first-parent", hash, "--", file.path }
	if file.old then
		table.insert(args, file.old)
	end
	return args
end

function Parse.files(text: string): { FileChange }
	local out: { FileChange } = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		local f = split(line, "\t")
		local status: string = string.sub(f[1], 1, 1)
		if (status == "R" or status == "C") and #f >= 3 then
			local change: FileChange = { status = status, path = f[3], old = f[2] }
			table.insert(out, change)
		elseif #f >= 2 and status ~= "" then
			local change: FileChange = { status = status, path = f[2] }
			table.insert(out, change)
		end
	end
	return out
end

function Parse.detail(show: string, files: string): Detail?
	local record = string.gsub(show, RS .. "%s*$", "")
	local f = split(record, FS)
	if #f < 8 then
		return nil
	end
	return {
		hash = f[1],
		parents = if f[2] == "" then {} else split(f[2], " "),
		author = f[3],
		email = f[4],
		time = tonumber(f[5]) or 0,
		committer = f[6],
		ctime = tonumber(f[7]) or 0,
		-- A message with `%x1f` in it would split further; keep the rest whole.
		body = trim(table.concat(f, FS, 8)),
		files = Parse.files(files),
	}
end

--- Web page of a commit for a GitHub or GitLab remote URL (https or scp-like ssh); nil for others.
function Parse.web_commit(remote: string, hash: string): string?
	local url = trim(remote)
	local host: string?, path: string? = nil, nil
	local rest = string.match(url, "^[%w+.-]+://(.+)$")
	if rest then
		rest = string.gsub(rest, "^[^@/]*@", "")
		host, path = string.match(rest, "^([^/:]+)[:%d]*/(.+)$")
	end
	if host == nil then
		host, path = string.match(url, "^[^@]+@([^:]+):(.+)$")
	end
	if host == nil or path == nil then
		return nil
	end
	path = string.gsub(path, "%.git$", "")
	path = string.gsub(path, "/+$", "")
	if host == "github.com" then
		return `https://github.com/{path}/commit/{hash}`
	elseif string.find(host, "gitlab", 1, true) then
		return `https://{host}/{path}/-/commit/{hash}`
	end
	return nil
end

--- Jira keys in `text` whose project is in `projects` (bare `[A-Z]+-\d+` also matches UTF-8, SHA-256).
function Parse.jira_keys(text: string, projects: { string }): { string }
	local allowed: { [string]: boolean } = {}
	for _, p in projects do
		allowed[p] = true
	end
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for project, number in string.gmatch(text, "%f[%w]([A-Z][A-Z0-9_]+)%-(%d+)%f[^%w]") do
		local key = `{project}-{number}`
		if allowed[project] and not seen[key] then
			seen[key] = true
			table.insert(out, key)
		end
	end
	return out
end

--- Short age: `now`, `5m`, `3h`, `2d`, `4mo`, `1y`.
function Parse.age(t: number, now: number): string
	local d = math.max(0, now - t)
	if d < 60 then
		return "now"
	elseif d < 3600 then
		return `{d // 60}m`
	elseif d < 86400 then
		return `{d // 3600}h`
	elseif d < 86400 * 30 then
		return `{d // 86400}d`
	elseif d < 86400 * 365 then
		return `{d // (86400 * 30)}mo`
	end
	return `{d // (86400 * 365)}y`
end

--- Folder name of a path, for titles.
function Parse.base(path: string): string
	local p = string.gsub(path, "[/\\]+$", "")
	return string.match(p, "([^/\\]+)$") or p
end

--- Same path regardless of slashes, case (Windows) and a trailing separator.
function Parse.norm(path: string): string
	local p = string.gsub(path, "\\", "/")
	p = string.gsub(p, "/+$", "")
	return string.lower(p)
end

return Parse
