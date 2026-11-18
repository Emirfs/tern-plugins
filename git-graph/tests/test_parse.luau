--!strict
local check = require("./check")
local parse = require("../lib/parse")
local repos = require("../lib/repos")

-- Decorations: current branch first, origin/HEAD dropped, tags and remotes kept
do
	local refs = parse.refs("HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1.0, refs/heads/feat/x")
	check.eq(#refs, 4, "origin/HEAD is dropped")
	check.eq(refs[1].name, "main", "current branch first")
	check.eq(refs[1].current, true, "HEAD -> marks current")
	check.eq(refs[2].name, "feat/x", "then other local branches")
	check.eq(refs[3].kind, "remote", "then remotes")
	check.eq(refs[4].kind, "tag", "tags last")
	check.eq(refs[4].name, "v1.0", "tag name without refs/tags")
	local detached = parse.refs("HEAD, refs/heads/main")
	check.eq(detached[1].kind, "head", "detached HEAD is its own ref")
end

-- Log records: unit/record separators, merges, roots, a subject with a comma
do
	local FS, RS = "\31", "\30"
	local a, b, m = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
	local text = table.concat({
		table.concat({ m, a .. " " .. b, "Emir", "1700000000", "merge: x, y", "HEAD -> refs/heads/main" }, FS),
		"\n" .. table.concat({ b, a, "Emir", "1699999000", "feat: b", "" }, FS),
		"\n" .. table.concat({ a, "", "Emir", "1699998000", "init", "tag: refs/tags/v0" }, FS),
		"\n",
	}, RS)
	local commits = parse.log(text)
	check.eq(#commits, 3, "three records")
	check.eq(#commits[1].parents, 2, "merge has two parents")
	check.eq(commits[1].subject, "merge: x, y", "subject kept whole")
	check.eq(commits[1].short, "ccccccc", "short hash")
	check.eq(#commits[3].parents, 0, "root has no parents")
	check.eq(commits[3].refs[1].name, "v0", "tag decoration")
end

-- Porcelain v2 status
do
	local st = parse.status(table.concat({
		"# branch.oid 1234",
		"# branch.head feat/x",
		"# branch.upstream origin/feat/x",
		"# branch.ab +2 -1",
		"1 .M N... 100644 100644 100644 aaa bbb file.c",
		"2 R. N... 100644 100644 100644 aaa bbb R100 new.c\told.c",
		"u UU N... 100644 100644 100644 100644 a b c conflict.c",
		"? notes.txt",
	}, "\n"))
	check.eq(st.branch, "feat/x", "branch")
	check.eq(st.upstream, "origin/feat/x", "upstream")
	check.eq(st.ahead, 2, "ahead")
	check.eq(st.behind, 1, "behind")
	check.eq(st.changed, 2, "ordinary and renamed entries count as changed")
	check.eq(st.conflicts, 1, "conflict")
	check.eq(st.untracked, 1, "untracked")
	check.eq(parse.status("# branch.head (detached)").detached, true, "detached HEAD")
end

-- Name-status lines, renames keep both paths
do
	local files = parse.files("M\tsrc/a.c\nR087\told/b.c\tnew/b.c\nA\tdocs/ç.md\n")
	check.eq(#files, 3, "three files")
	check.eq(files[2].status, "R", "rename status letter")
	check.eq(files[2].old, "old/b.c", "rename keeps the old path")
	check.eq(files[2].path, "new/b.c", "rename path is the new one")
	check.eq(files[3].path, "docs/ç.md", "non-ASCII path unquoted")
	local args = parse.diff_args("abc", files[2])
	check.eq(args[#args], "old/b.c", "a rename's diff names both paths")
end

-- Web commit URLs
do
	local h = "0123456789"
	check.eq(parse.web_commit("https://github.com/Emirfs/tern-plugins.git", h), "https://github.com/Emirfs/tern-plugins/commit/" .. h, "https github")
	check.eq(parse.web_commit("git@github.com:Emirfs/ghd.git\n", h), "https://github.com/Emirfs/ghd/commit/" .. h, "scp-like ssh")
	check.eq(parse.web_commit("https://user@github.com/o/r", h), "https://github.com/o/r/commit/" .. h, "userinfo")
	check.eq(parse.web_commit("ssh://git@gitlab.example.com:2222/team/app.git", h), "https://gitlab.example.com/team/app/-/commit/" .. h, "gitlab with port")
	check.eq(parse.web_commit("C:/repos/local.git", h), nil, "a local path has no web page")
end

-- Jira keys only for configured projects: UTF-8 and SHA-256 are not cards
do
	local keys = parse.jira_keys("FRMWR-397: fix UTF-8 and SHA-256 (see FRMWR-12, FRMWR-397)", { "FRMWR" })
	check.same(keys, { "FRMWR-397", "FRMWR-12" }, "configured keys, once each, in order")
	check.same(parse.jira_keys("XFRMWR-1 FRMWR-2x", { "FRMWR" }), {}, "keys must stand alone")
end

-- Ages and paths
do
	check.eq(parse.age(1000, 1030), "şimdi", "seconds")
	check.eq(parse.age(0, 7200), "2 sa", "hours")
	check.eq(parse.age(0, 86400 * 400), "1 yıl", "years")
	check.eq(parse.base("C:\\Users\\x\\GitHub\\repo\\"), "repo", "base of a Windows path")
	check.eq(parse.norm("C:\\A\\b\\"), parse.norm("c:/a/B"), "norm ignores slashes, case and a trailing separator")
end

-- Repo discovery: stops at a repo, skips heavy and hidden folders, honours depth
do
	local tree: { [string]: { string } } = {
		["R"] = { "a", "b", "node_modules", ".cache", "file.txt" },
		["R/a"] = { ".git", "sub" },
		["R/a/sub"] = { ".git" },
		["R/b"] = { "c" },
		["R/b/c"] = { ".git" },
		["R/node_modules"] = { "x" },
		["R/node_modules/x"] = { ".git" },
	}
	local function list(path: string): { string }
		local names = tree[path]
		if names == nil then
			error("not a directory: " .. path)
		end
		return names
	end
	local found = repos.scan("R", list, 4, 100)
	check.eq(#found, 2, "two repos")
	check.eq(found[1].rel, "a", "repo found at depth 1")
	check.eq(found[2].rel, "b/c", "repo found at depth 2")
	check.eq(found[2].path, "R/b/c", "path joined with the root's separator")
	check.eq(#repos.scan("R", list, 1, 100), 1, "depth 1 does not reach b/c")
	check.eq(#repos.scan("R", list, 4, 1), 1, "limit caps the result")
end
