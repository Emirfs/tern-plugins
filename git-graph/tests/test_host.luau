--!strict
-- The block end to end: host.luau in a fake runtime whose processes are real git runs in a scratch repo.
-- Process callbacks are queued and flushed, as Tern delivers them later on the VM thread.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local check = require("./check")

local tmp = (process.env.TEMP or "/tmp") .. "/git-graph-host-" .. tostring(os.time())
fs.writeDir(tmp)
local ENV = {
	GIT_AUTHOR_NAME = "Test", GIT_AUTHOR_EMAIL = "t@example.com",
	GIT_COMMITTER_NAME = "Test", GIT_COMMITTER_EMAIL = "t@example.com",
	GIT_CONFIG_GLOBAL = tmp .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1",
}
fs.writeFile(tmp .. "/gitconfig", "")
local repo = tmp .. "/repo"
fs.writeDir(repo)

local function sh(args: { string })
	local r = process.exec("git", args, { cwd = repo, env = ENV })
	if not r.ok then
		error(r.stderr)
	end
end

local function text(node: any): string
	local out: { string } = {}
	local function walk(n: any)
		if type(n) == "string" then
			table.insert(out, n)
		elseif type(n) == "table" then
			if type(n.t) == "string" then
				table.insert(out, n.t)
			end
			for k, v in n do
				if k ~= "t" and k ~= "s" then
					walk(v)
				end
			end
		end
	end
	walk(node)
	return table.concat(out, "\n")
end

local function has(s: string, needle: string): boolean
	return string.find(s, needle, 1, true) ~= nil
end

local ok, err = pcall(function()
	sh({ "init", "-q", "-b", "main" })
	fs.writeFile(repo .. "/a.txt", "one\n")
	sh({ "add", "a.txt" })
	sh({ "commit", "-q", "-m", "init" })
	sh({ "branch", "side" })
	fs.writeFile(repo .. "/a.txt", "one\ntwo\n")
	sh({ "commit", "-q", "-am", "FRMWR-397: second line" })

	-- Fake runtime
	local queue: { () -> () } = {}
	local kv: { [string]: any } = {}
	local timers: { () -> () } = {}
	local toasts: { string } = {}
	local copied: { string } = {}
	local spawned: { { string } } = {}
	local blocks: { [string]: any } = {}
	local function node(kind: string): (...any) -> any
		return function(...: any): any
			return { k = kind, a = { ... } }
		end
	end
	local ui: { [string]: any } = {}
	for _, k in { "text", "col", "row", "table", "card", "section", "progress", "md", "kv", "diff", "button", "lines", "code" } do
		ui[k] = node(k)
	end
	ui.span = function(t: string, s: string?): any
		return { t = t, s = s }
	end
	local tern = {
		ui = ui,
		plugin = { data = tmp .. "/data", dir = tmp },
		getenv = function(name: string): string?
			return if name == "USERPROFILE" then tmp else nil
		end,
		json = { decode = function(s: string): any return serde.decode("json", s) end },
		now = function(): number return os.clock() end,
		kv = {
			get = function(k: string): any return kv[k] end,
			set = function(k: string, v: any) kv[k] = v end,
		},
		fs = {
			exists = function(p: string): boolean return fs.isFile(p) or fs.isDir(p) end,
			read = function(p: string): string return fs.readFile(p) end,
			list = function(p: string): { string } return fs.readDir(p) end,
		},
		process = {
			run = function(argv: { string }, opts: any, cb: (any, any) -> ())
				table.insert(spawned, argv)
				table.insert(queue, function()
					local r = process.exec(argv[1], { table.unpack(argv, 2) }, { env = ENV, stdin = opts and opts.stdin })
					cb({ status = r.code, stdout = r.stdout, stderr = r.stderr, timed_out = false }, nil)
				end)
			end,
		},
		timer = function(_ms: number, fn: () -> ())
			table.insert(timers, fn)
		end,
		block = { define = function(id: string, def: any) blocks[id] = def end },
	}
	local renders = 0
	local cx = {
		pane = 7, cwd = nil, cols = 120, rows = 40,
		render = function() renders += 1 end,
		toast = function(_self: any, level: string, msg: string) table.insert(toasts, level .. ": " .. msg) end,
		copy = function(_self: any, s: string) table.insert(copied, s) end,
		open = function() end,
	}
	local function flush()
		while #queue > 0 do
			table.remove(queue, 1)()
		end
	end
	local function run_timers()
		local due = timers
		timers = {}
		for _, fn in due do
			fn()
		end
		flush()
	end

	local root = "git-graph"
	local cache: { [string]: any } = {}
	local function load(path: string): any
		if cache[path] ~= nil then
			return cache[path]
		end
		local dir = string.match(path, "^(.*)/[^/]+$") or "."
		local function req(rel: string): any
			return load((string.gsub(rel, "^%./", dir .. "/")) .. ".luau")
		end
		local chunk = luau.load(luau.compile(fs.readFile(path)), { environment = { tern = tern, require = req } })
		local value = chunk()
		cache[path] = if value == nil then true else value
		return cache[path]
	end
	load(root .. "/host.luau")
	local block = blocks.graph

	-- A pinned repo: history, lanes, refs and the newest commit's detail
	local state = block.init(cx, { repo }, nil)
	flush()
	check.eq(state.follow, false, "a launch path pins the repo")
	check.eq(#state.commits, 2, "both commits read")
	check.eq(block.title(state), "Git · repo · main", "title names repo and branch")
	local view = block.view(state, cx)
	local main = text(view.main)
	check.truthy(has(main, "FRMWR-397: second line"), "subject shown")
	check.truthy(has(main, "◉"), "head glyph drawn")
	check.truthy(has(main, "side"), "branch chip on the first commit")
	check.truthy(has(text(view.dock), "a.txt"), "detail lists the changed file")
	check.eq(view.layer, nil, "no diff open yet")

	-- Enter opens the selected file's diff above the graph; escape closes it
	block.key(state, { name = "enter", ctrl = false, alt = false, meta = false, shift = false }, cx)
	flush()
	check.truthy(has(text(block.view(state, cx).layer), "+two"), "diff layer shows the change")
	block.key(state, { name = "escape", ctrl = false, alt = false, meta = false, shift = false }, cx)
	check.eq(block.view(state, cx).layer, nil, "escape closes the diff")

	-- Narrow pane: author, hash and toolbar hidden by default; Görünüm toggles a part and survives a save
	cx.cols = 60
	local narrow = text(block.view(state, cx).main)
	check.eq(has(narrow, "Test"), false, "author column hidden when narrow")
	check.eq(has(narrow, "Depolar"), false, "toolbar hidden when narrow")
	check.truthy(has(narrow, "FRMWR-397: second line"), "subjects still shown")
	block.key(state, { name = "v", text = "v", ctrl = false, alt = false, meta = false, shift = false }, cx)
	check.truthy(has(text(block.view(state, cx).layer), "Dar pane"), "v opens the Görünüm panel")
	block.event(state, { ev = "action", id = "parts", act = "layout", value = "narrow:author", item = "author" }, cx)
	check.truthy(has(text(block.view(state, cx).main), "Test"), "author turned on for narrow panes")
	block.event(state, { ev = "action", act = "threshold", value = "here" }, cx)
	check.eq(state.layout.threshold, 60, "threshold set to the current width")
	check.eq(block.save(state).layout.narrow.author, true, "layout saved with the pane")
	block.event(state, { ev = "action", act = "layout-default" }, cx)
	check.eq(kv["layout-default"].narrow.author, true, "made the default for new panes")
	block.key(state, { name = "escape", ctrl = false, alt = false, meta = false, shift = false }, cx)
	check.eq(state.settings, false, "escape closes Görünüm")
	cx.cols = 120

	-- Menu: copy, Jira link and a switch to `side` that waits for the window's confirm
	local first = state.commits[1]
	local second = state.commits[2]
	block.event(state, { ev = "action", id = "commits", act = "Hash'i kopyala", item = first.hash }, cx)
	check.eq(copied[1], first.hash, "copy puts the full hash on the clipboard")
	local menu: { string } = nil :: any
	for _, row in (view.main.a[1][3].a[2] :: { any }) do
		if row.id == second.hash then
			menu = row.menu
		end
	end
	check.truthy(menu and table.find(menu, "Dala geç: side") ~= nil, "switch offered for a branch on the commit")

	block.event(state, { ev = "action", id = "commits", act = "Dala geç: side", item = second.hash }, cx)
	flush()
	local ask = kv.ask
	check.truthy(ask and ask.kind == "pick" and ask.pane == 7, "the switch asks the window to confirm")
	kv["answer:7"] = { id = ask.id, value = "yes" }
	run_timers()
	flush()
	local head = process.exec("git", { "branch", "--show-current" }, { cwd = repo, env = ENV }).stdout
	check.eq(string.match(head, "%S+"), "side", "confirmed switch ran git switch")
	check.eq(kv["answer:7"], nil, "the answer is consumed")

	-- A dirty tree refuses the switch before asking
	fs.writeFile(repo .. "/a.txt", "dirty\n")
	kv.ask = nil
	block.event(state, { ev = "action", id = "commits", act = "Dala geç: main", item = first.hash }, cx)
	flush()
	check.eq(kv.ask, nil, "no confirm with uncommitted changes")
	check.truthy(has(toasts[#toasts], "Dala geçilmedi"), "the refusal is toasted")

	-- Following focus: a folder outside any repo keeps the repo and says why
	block.event(state, { ev = "action", act = "pin" }, cx)
	check.eq(state.follow, true, "pin toggles back to following")
	kv.focus = { cwd = tmp }
	run_timers()
	flush()
	check.eq(state.repo ~= nil and string.find(state.repo, "repo", 1, true) ~= nil, true, "repo kept outside a repo")
	check.truthy(state.note and has(state.note, "Git deposu değil"), "note explains")

	-- AI: the configured argv gets the commit on stdin, the answer is cached in kv
	fs.writeDir(tmp .. "/data")
	fs.writeFile(tmp .. "/data/config.json", serde.encode("json", { ai_argv = { "git", "--version" } }))
	state.cfg.ai_argv = { "git", "--version" }
	block.event(state, { ev = "action", act = "ai" }, cx)
	flush()
	check.truthy(state.ai[state.selected] and has(state.ai[state.selected], "git version"), "AI answer shown")
	check.truthy(kv["ai:" .. state.selected] ~= nil, "AI answer cached")
	check.truthy(renders > 0, "renders after async work")
end)
fs.removeDir(tmp)
if not ok then
	error(err, 0)
end
