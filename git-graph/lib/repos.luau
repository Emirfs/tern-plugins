--!strict
-- Finds git repositories under a folder: every directory holding `.git` (a folder, or the file a worktree
-- or submodule has). Walks with a directory listing only, so it takes `list` (raises for non-directories)
-- instead of calling Tern, and lune tests feed it a fake tree.

local Repos = {}

-- Folders that never hold a repo of their own but can be huge.
local SKIP: { [string]: boolean } = {
	[".git"] = true, node_modules = true, [".venv"] = true, venv = true, __pycache__ = true,
	[".history"] = true, [".cache"] = true, target = true, dist = true, build = true,
	[".tmp.driveupload"] = true, [".tmp.drivedownload"] = true, ["$RECYCLE.BIN"] = true,
}

export type Repo = { path: string, rel: string }

--- Repos under `root` down to `depth` levels; a repo's own subfolders are not searched (nested repos
--- inside a repo are rare and walking a checkout is the slow part). `limit` caps the result.
function Repos.scan(root: string, list: (string) -> { string }, depth: number, limit: number): { Repo }
	local out: { Repo } = {}
	local sep = if string.find(root, "\\", 1, true) then "\\" else "/"
	local function walk(dir: string, rel: string, level: number)
		if #out >= limit then
			return
		end
		local ok, names = pcall(list, dir)
		if not ok or type(names) ~= "table" then
			return
		end
		for _, name in names do
			if name == ".git" then
				table.insert(out, { path = dir, rel = if rel == "" then "." else rel })
				return
			end
		end
		if level >= depth then
			return
		end
		for _, name in names do
			if not SKIP[name] and string.sub(name, 1, 1) ~= "." then
				walk(dir .. sep .. name, if rel == "" then name else rel .. "/" .. name, level + 1)
			end
		end
	end
	walk((string.gsub(root, "[/\\]+$", "")), "", 0)
	table.sort(out, function(a, b)
		return string.lower(a.rel) < string.lower(b.rel)
	end)
	return out
end

return Repos
