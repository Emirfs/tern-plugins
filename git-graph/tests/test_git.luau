--!strict
-- Real git in a scratch repo: the command lines in lib/parse produce what its parsers read.
local fs = require("@lune/fs")
local process = require("@lune/process")
local check = require("./check")
local lanes = require("../lib/lanes")
local parse = require("../lib/parse")

local tmp = (process.env.TEMP or process.env.TMPDIR or "/tmp") .. "/git-graph-test-" .. tostring(os.time())
fs.writeDir(tmp)

local ENV = {
	GIT_AUTHOR_NAME = "Test", GIT_AUTHOR_EMAIL = "t@example.com",
	GIT_COMMITTER_NAME = "Test", GIT_COMMITTER_EMAIL = "t@example.com",
	GIT_CONFIG_GLOBAL = tmp .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1",
}
fs.writeFile(tmp .. "/gitconfig", "")

local tick = 1700000000
local function git(args: { string }): string
	tick += 60
	local env = table.clone(ENV)
	env.GIT_AUTHOR_DATE = `{tick} +0000`
	env.GIT_COMMITTER_DATE = `{tick} +0000`
	local argv = parse.git(tmp, args)
	local result = process.exec(argv[1], { table.unpack(argv, 2) }, { env = env })
	if not result.ok then
		error(`git {table.concat(args, " ")}: {result.stderr}`)
	end
	return result.stdout
end

local ok, err = pcall(function()
	git({ "init", "-q", "-b", "main" })
	fs.writeFile(tmp .. "/a.txt", "one\n")
	git({ "add", "a.txt" })
	git({ "commit", "-q", "-m", "init" })
	git({ "switch", "-q", "-c", "feat/x" })
	fs.writeFile(tmp .. "/b.txt", "feature\n")
	git({ "add", "b.txt" })
	git({ "commit", "-q", "-m", "FRMWR-397: add b" })
	git({ "switch", "-q", "main" })
	fs.writeFile(tmp .. "/a.txt", "one\ntwo\n")
	git({ "commit", "-q", "-am", "main: two" })
	git({ "merge", "-q", "--no-ff", "-m", "merge feat/x", "feat/x" })
	git({ "tag", "v1" })
	git({ "mv", "a.txt", "c.txt" })
	git({ "commit", "-q", "-m", "rename a to c" })

	local commits = parse.log(git(parse.log_args(false, 0, 400)))
	check.eq(#commits, 5, "five commits")
	check.eq(commits[1].subject, "rename a to c", "newest first")
	check.eq(commits[1].refs[1].name, "main", "HEAD branch decorates the tip")
	check.eq(commits[1].refs[1].current, true, "tip is current")
	local merge = commits[2]
	check.eq(#merge.parents, 2, "merge commit parsed with two parents")
	check.eq(merge.refs[1].name, "v1", "tag on the merge")

	local head = string.match(git({ "rev-parse", "HEAD" }), "%x+")
	local rows = lanes.layout(commits :: { any }, head)
	local drawn = {}
	for _, row in rows do
		local s = {}
		for _, cell in row.cells do
			table.insert(s, cell.ch)
		end
		table.insert(drawn, table.concat(s))
	end
	check.eq(drawn[1], "◉", "head row")
	check.eq(drawn[2], "○─╮", "merge row opens the feature lane")
	check.eq(drawn[#drawn], "●─╯", "lanes meet at init")

	local st = parse.status(git({ "status", "--porcelain=v2", "--branch" }))
	check.eq(st.branch, "main", "status branch")
	check.eq(st.changed, 0, "clean tree")

	-- Merge files are what the merge brought over the first parent; the rename keeps both paths.
	local d = parse.detail(git(parse.show_args(merge.hash)), git(parse.files_args(merge.hash)))
	check.truthy(d ~= nil, "merge detail parsed")
	local detail = d :: parse.Detail
	check.eq(#detail.files, 1, "merge brought one file")
	check.eq(detail.files[1].path, "b.txt", "the feature's file")
	check.eq(detail.body, "merge feat/x", "message body")

	local r = parse.detail(git(parse.show_args(commits[1].hash)), git(parse.files_args(commits[1].hash))) :: parse.Detail
	check.eq(r.files[1].status, "R", "rename detected")
	check.eq(r.files[1].old, "a.txt", "rename's old path")
	local diff = git(parse.diff_args(r.hash, r.files[1]))
	check.truthy(string.find(diff, "rename from a.txt", 1, true), "rename diff names both sides")

	local root = commits[#commits]
	local rd = parse.detail(git(parse.show_args(root.hash)), git(parse.files_args(root.hash))) :: parse.Detail
	check.eq(rd.files[1].path, "a.txt", "root commit lists its files")
	check.truthy(string.find(git(parse.diff_args(root.hash, rd.files[1])), "+one", 1, true), "root commit diff")

	check.same(parse.jira_keys(commits[4].subject, { "FRMWR" }), { "FRMWR-397" }, "Jira key from a real subject")
	check.eq(#parse.log(git(parse.log_args(false, 2, 2))), 2, "paging with skip")
end)
fs.removeDir(tmp)
if not ok then
	error(err, 0)
end
