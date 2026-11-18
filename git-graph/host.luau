--!strict
-- `graph` block: a repository's commit graph (one colored lane per branch), the selected commit's message,
-- parents and changed files, and a file's diff above the graph. Reads with git; the only writes are the
-- safe ones the user starts: switch to a branch (clean tree, after a confirm), create a branch, fetch.
--
-- Which repo: launch argument (pinned), otherwise it follows the folder of the focused terminal, which the
-- window half publishes in kv `focus`. Pickers and prompts exist only in the window half: the block asks
-- through kv `ask` and reads the reply from kv `answer:<pane>`.

local lanes = require("./lib/lanes")
local layout = require("./lib/layout")
local parse = require("./lib/parse")
local repos = require("./lib/repos")

local ui = tern.ui

local PAGE = 400
local POLL_MS = 15000
local TICK_MS = 1000
local GIT_TIMEOUT_MS = 20000
local FETCH_TIMEOUT_MS = 180000
local AI_TIMEOUT_MS = 120000
local MAX_DIFF = 400000
local MAX_AI_INPUT = 12000

local ACT_COPY = "Hash'i kopyala"
local ACT_WEB = "Web'de aç"
local ACT_BRANCH = "Buradan dal aç…"
local ACT_AI = "AI'a açıklat"
local SWITCH = "Dala geç: "
local JIRA = "Jira: "
local NOTE = "Hafıza notu: "

type Config = {
	roots: { string },
	depth: number,
	jira_url: string,
	jira_projects: { string },
	vault: string,
	ai_argv: { string },
}
type Ask = { kind: string, run: (value: any) -> () }
type DiffView = { path: string, text: string?, err: string? }
type State = {
	cx: BlockCx,
	closed: boolean,
	cfg: Config,
	follow: boolean,
	repo: string?,
	-- Last focus folder handled, so a tick only resolves a new one.
	seen: string?,
	remotes: boolean,
	commits: { parse.Commit },
	rows: { lanes.Row },
	more: boolean,
	loading: boolean,
	err: string?,
	note: string?,
	status: parse.Status?,
	sig: string?,
	head: string?,
	web: string?,
	fetched: number?,
	selected: string?,
	details: { [string]: parse.Detail },
	file: number,
	diff: DiffView?,
	ai: { [string]: string },
	ai_busy: { [string]: boolean },
	busy: string?,
	asks: { [string]: Ask },
	-- Bumped on every repo change: answers from git about an older repo are dropped.
	gen: number,
	-- What shows narrow and wide (Görünüm) and whether its panel is open.
	layout: layout.Layout,
	settings: boolean,
}

local function home(): string
	return tern.getenv("USERPROFILE") or tern.getenv("HOME") or "."
end

local function config(): Config
	local h = home()
	local cfg: Config = {
		roots = { h .. "\\GitHub" },
		depth = 4,
		jira_url = "https://inohom64.atlassian.net",
		jira_projects = { "FRMWR" },
		vault = h .. "\\GitHub\\araclar\\hafiza",
		ai_argv = {
			"omp", "-p", "--no-tools", "--no-session", "--no-extensions", "--no-skills", "--no-rules",
			"--no-context-files", "--model", "haiku", "--system-prompt",
			"Bir git commit'ini Türkçe açıklayan kod inceleyicisin. En fazla 5 kısa madde: ne değişti, " ..
				"mesajdan anlaşılıyorsa neden, dikkat edilecek risk. Tahmin yürütme; diff'te olmayanı yazma.",
		},
	}
	local path = tern.plugin.data .. "/config.json"
	if not tern.fs.exists(path) then
		return cfg
	end
	local ok, raw = pcall(function()
		return tern.json.decode(tern.fs.read(path, 65536))
	end)
	if not ok or type(raw) ~= "table" then
		return cfg
	end
	if type(raw.roots) == "table" and #raw.roots > 0 then
		cfg.roots = raw.roots
	end
	if type(raw.depth) == "number" then
		cfg.depth = math.clamp(raw.depth, 1, 8)
	end
	if type(raw.jira_url) == "string" then
		cfg.jira_url = string.gsub(raw.jira_url, "/+$", "")
	end
	if type(raw.jira_projects) == "table" then
		cfg.jira_projects = raw.jira_projects
	end
	if type(raw.vault) == "string" then
		cfg.vault = raw.vault
	end
	if type(raw.ai_argv) == "table" and #raw.ai_argv > 0 then
		cfg.ai_argv = raw.ai_argv
	end
	return cfg
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function render(state: State)
	-- A pane closed with × has no hook: a failing render ends the timer chains.
	if not state.closed and not pcall(state.cx.render, state.cx) then
		state.closed = true
	end
end

local function first_line(s: string): string
	return string.match(s, "^%s*([^\r\n]+)") or ""
end

-- Runs git in the current repo; `cb` gets (ok, stdout, error text). Drops answers from an older repo.
local function git(state: State, args: { string }, cb: (boolean, string, string) -> (), timeout: number?)
	local repo = state.repo
	if repo == nil then
		cb(false, "", "Depo seçilmedi.")
		return
	end
	local gen = state.gen
	local ok, err = pcall(function()
		tern.process.run(parse.git(repo, args), {
			timeout_ms = timeout or GIT_TIMEOUT_MS,
			env = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" },
		}, function(result: ProcessResult, _)
			if state.closed or gen ~= state.gen then
				return
			end
			if result.timed_out then
				cb(false, result.stdout, "git zaman aşımına uğradı")
			elseif result.status ~= 0 then
				cb(false, result.stdout, first_line(result.stderr) ~= "" and first_line(result.stderr) or `git çıkış kodu {result.status}`)
			else
				cb(true, result.stdout, "")
			end
		end)
	end)
	if not ok then
		cb(false, "", `git başlatılamadı: {err}`)
	end
end

local function find(state: State, hash: string?): parse.Commit?
	for _, c in state.commits do
		if c.hash == hash then
			return c
		end
	end
	return nil
end

local function relayout(state: State)
	state.rows = lanes.layout(state.commits :: { any }, state.head)
end

local load_detail: (State, string) -> ()

local function select(state: State, hash: string?)
	if hash == state.selected then
		return
	end
	state.selected = hash
	state.file = 1
	if hash then
		load_detail(state, hash)
	end
end

-- Reads one page of history; `reset` starts over (repo change, refs moved), else appends the next page.
local function load_log(state: State, reset: boolean)
	local skip = if reset then 0 else #state.commits
	-- After refs move, reload as much as was shown so the view does not shrink under the user.
	local count = if reset then math.max(PAGE, #state.commits) else PAGE
	git(state, parse.log_args(state.remotes, skip, count), function(ok, out, why)
		state.loading = false
		if not ok then
			-- An empty repo has no HEAD to log yet.
			if string.find(why, "does not have any commits", 1, true) or string.find(why, "unknown revision", 1, true) then
				state.commits, state.rows, state.more, state.err = {}, {}, false, nil
			else
				state.err = why
			end
			render(state)
			return
		end
		local page = parse.log(out)
		if reset then
			state.commits = page
		else
			table.move(page, 1, #page, #state.commits + 1, state.commits)
		end
		state.more = #page == count
		state.err = nil
		state.fetched = os.time()
		relayout(state)
		if state.selected == nil or find(state, state.selected) == nil then
			select(state, if state.commits[1] then state.commits[1].hash else nil)
		end
		render(state)
	end)
end

-- Status and the ref signature; history is re-read only when the signature moved (or `force`).
local function poll(state: State, force: boolean)
	if state.repo == nil then
		return
	end
	git(state, { "status", "--porcelain=v2", "--branch", "--untracked-files=normal" }, function(ok, out, _)
		if ok then
			state.status = parse.status(out)
		end
		git(state, { "for-each-ref", "--format=%(objectname) %(refname)" }, function(ok2, refs, why)
			git(state, { "rev-parse", "HEAD" }, function(ok3, head, _)
				local sig = parse.signature(if ok2 then refs else "", if ok3 then head else "")
				state.head = if ok3 then string.match(head, "%x+") else nil
				if not ok2 then
					state.err = why
					render(state)
				elseif force or sig ~= state.sig then
					state.sig = sig
					state.loading = true
					render(state)
					load_log(state, true)
				else
					render(state)
				end
			end)
		end)
	end)
end

local function set_repo(state: State, path: string?, follow: boolean)
	state.follow = follow
	if path and state.repo and parse.norm(path) == parse.norm(state.repo) then
		return
	end
	state.gen += 1
	state.repo = path
	state.commits, state.rows, state.details, state.ai = {}, {}, {}, {}
	state.selected, state.diff, state.sig, state.status, state.head, state.web = nil, nil, nil, nil, nil, nil
	state.err, state.more, state.file = nil, false, 1
	if path == nil then
		return
	end
	state.loading = true
	poll(state, true)
	git(state, { "remote", "get-url", "origin" }, function(ok, out, _)
		state.web = if ok then string.match(out, "^%s*(%S+)") else nil
	end)
end

-- Resolves `dir` to its repo root; outside a repo the current repo stays, with a note.
local function open_dir(state: State, dir: string, follow: boolean)
	local probe: State = state
	local gen = state.gen
	local ok, err = pcall(function()
		tern.process.run(parse.git(dir, { "rev-parse", "--show-toplevel" }), { timeout_ms = GIT_TIMEOUT_MS }, function(result: ProcessResult, _)
			if probe.closed or gen ~= probe.gen then
				return
			end
			local top = if result.status == 0 then string.match(result.stdout, "^%s*(.-)%s*$") else nil
			if top and top ~= "" then
				probe.note = nil
				set_repo(probe, top, follow)
			else
				probe.note = `Git deposu değil: {dir}`
			end
			render(probe)
		end)
	end)
	if not ok then
		state.err = `git başlatılamadı: {err}`
	end
end

load_detail = function(state: State, hash: string)
	if state.details[hash] then
		return
	end
	git(state, parse.show_args(hash), function(ok, show, why)
		if not ok then
			state.err = why
			render(state)
			return
		end
		git(state, parse.files_args(hash), function(ok2, files, _)
			local d = parse.detail(show, if ok2 then files else "")
			if d then
				state.details[hash] = d
			end
			render(state)
		end)
	end)
	local cached = tern.kv.get("ai:" .. hash)
	if type(cached) == "string" then
		state.ai[hash] = cached
	end
end

local function open_diff(state: State)
	local d = if state.selected then state.details[state.selected] else nil
	if d == nil or #d.files == 0 then
		return
	end
	local file = d.files[math.clamp(state.file, 1, #d.files)]
	local view: DiffView = { path = file.path }
	state.diff = view
	git(state, parse.diff_args(d.hash, file), function(ok, out, why)
		if state.diff ~= view then
			return
		end
		if not ok then
			view.err = why
		elseif #out > MAX_DIFF then
			view.text = string.sub(out, 1, MAX_DIFF)
			view.err = "Diff çok büyük; ilk 400 KB gösteriliyor."
		else
			view.text = out
		end
		render(state)
	end)
end

-- ---------------------------------------------------------------- asks to the window half

local ask_seq = 0
local function ask(state: State, window: string?, kind: string, opts: { [string]: any }, run: (any) -> ())
	ask_seq += 1
	local id = `{state.cx.pane}:{string.format("%.3f", tern.now())}:{ask_seq}`
	state.asks[id] = { kind = kind, run = run }
	opts.id, opts.pane, opts.kind, opts.window = id, state.cx.pane, kind, window
	tern.kv.set("ask", opts)
end

local function take_answer(state: State)
	local key = `answer:{state.cx.pane}`
	local a = tern.kv.get(key)
	if type(a) ~= "table" or type(a.id) ~= "string" then
		return
	end
	tern.kv.set(key, nil)
	local pending = state.asks[a.id]
	state.asks[a.id] = nil
	if pending and a.value ~= nil then
		pending.run(a.value)
	end
end

-- ---------------------------------------------------------------- actions

local function vault_note(state: State, rel: string): string?
	local path = state.cfg.vault .. "\\" .. string.gsub(rel, "/", "\\")
	return if tern.fs.exists(path) then path else nil
end

local function jira_keys(state: State, c: parse.Commit): { string }
	local d = state.details[c.hash]
	return parse.jira_keys(c.subject .. "\n" .. (if d then d.body else ""), state.cfg.jira_projects)
end

local function switch_to(state: State, ref: parse.Ref, window: string?)
	git(state, { "status", "--porcelain", "--untracked-files=no" }, function(ok, out, why)
		if not ok then
			state.cx:toast("error", "Durum okunamadı", why)
			return
		end
		if string.match(out, "%S") then
			state.cx:toast("error", "Dala geçilmedi", "Kaydedilmemiş değişiklik var; önce commit ya da stash.")
			return
		end
		local target = if ref.kind == "remote" then string.match(ref.name, "^[^/]+/(.+)$") or ref.name else ref.name
		ask(state, window, "pick", {
			placeholder = `{target} dalına geçilsin mi?`,
			items = {
				{ label = `Geç: {target}`, detail = if ref.kind == "remote" then `{ref.name} izlenerek yerel dal açılır` else nil, value = "yes" },
				{ label = "Vazgeç", value = "no" },
			},
		}, function(value)
			if value ~= "yes" then
				return
			end
			local args = if ref.kind == "remote" then { "switch", "--track", ref.name } else { "switch", ref.name }
			state.busy = "switch"
			render(state)
			git(state, args, function(ok2, _, why2)
				state.busy = nil
				if ok2 then
					state.cx:toast("success", `{target} dalına geçildi`)
				else
					state.cx:toast("error", "Dala geçilemedi", why2)
				end
				poll(state, false)
			end)
		end)
	end)
end

local function create_branch(state: State, c: parse.Commit, window: string?)
	ask(state, window, "prompt", { placeholder = `Yeni dal adı ({c.short} commit'inden)` }, function(value)
		local name = if type(value) == "string" then string.match(value, "^%s*(.-)%s*$") else nil
		if name == nil or name == "" then
			return
		end
		git(state, { "check-ref-format", "--branch", name }, function(valid, _, _)
			if not valid then
				state.cx:toast("error", "Geçersiz dal adı", name)
				return
			end
			git(state, { "branch", "--", name, c.hash }, function(ok, _, why)
				if ok then
					state.cx:toast("success", `{name} dalı açıldı`, "Geçmek için sağ tık → Dala geç.")
				else
					state.cx:toast("error", "Dal açılamadı", why)
				end
				poll(state, false)
			end)
		end)
	end)
end

local function fetch(state: State)
	if state.busy or state.repo == nil then
		return
	end
	state.busy = "fetch"
	render(state)
	git(state, { "fetch", "--all", "--quiet" }, function(ok, _, why)
		state.busy = nil
		if not ok then
			state.cx:toast("error", "Fetch başarısız", why)
		end
		poll(state, false)
	end, FETCH_TIMEOUT_MS)
end

local function explain(state: State, c: parse.Commit)
	if state.ai_busy[c.hash] or state.ai[c.hash] then
		return
	end
	state.ai_busy[c.hash] = true
	render(state)
	git(state, { "show", "--stat", "--patch", "-U2", "--no-color", "--diff-merges=first-parent", "--format=commit %H%nAuthor: %an%nDate: %ad%n%n%B", c.hash }, function(ok, out, why)
		if not ok then
			state.ai_busy[c.hash] = nil
			state.cx:toast("error", "Commit okunamadı", why)
			render(state)
			return
		end
		local input = if #out > MAX_AI_INPUT then string.sub(out, 1, MAX_AI_INPUT) .. "\n… (diff kısaltıldı)" else out
		local gen = state.gen
		local started, err = pcall(function()
			tern.process.run(state.cfg.ai_argv, { timeout_ms = AI_TIMEOUT_MS, stdin = input }, function(result: ProcessResult, _)
				state.ai_busy[c.hash] = nil
				if state.closed or gen ~= state.gen then
					return
				end
				local text = string.match(result.stdout, "^%s*(.-)%s*$") or ""
				if result.status == 0 and text ~= "" then
					state.ai[c.hash] = text
					tern.kv.set("ai:" .. c.hash, text)
				else
					state.cx:toast("error", "AI açıklaması alınamadı", first_line(result.stderr) ~= "" and first_line(result.stderr) or first_line(result.stdout))
				end
				render(state)
			end)
		end)
		if not started then
			state.ai_busy[c.hash] = nil
			state.cx:toast("error", "AI başlatılamadı", tostring(err))
			render(state)
		end
	end)
end

local function pick_repo(state: State, window: string?)
	local items: { { [string]: any } } = {
		{ label = "Odaktaki terminali izle", detail = "Odaklanan terminalin klasörü değiştikçe depo da değişir", value = "", current = state.follow },
	}
	local cur = if state.repo then parse.norm(state.repo) else nil
	for _, root in state.cfg.roots do
		for _, r in repos.scan(root, tern.fs.list, state.cfg.depth, 500) do
			table.insert(items, {
				label = r.rel, detail = r.path, group = parse.base(root), value = r.path,
				current = not state.follow and cur == parse.norm(r.path),
			})
		end
	end
	ask(state, window, "pick", { placeholder = "Depo seç (yazarak süz)", icon = "git-branch", items = items }, function(value)
		if value == "" then
			state.follow = true
			state.seen = nil
		elseif type(value) == "string" then
			set_repo(state, value, false)
		end
		render(state)
	end)
end

local function toggle_pin(state: State)
	if state.follow then
		state.follow = false
	else
		state.follow = true
		state.seen = nil
	end
end

local function on_commit_action(state: State, name: string, c: parse.Commit, window: string?)
	if name == ACT_COPY then
		state.cx:copy(c.hash)
		state.cx:toast("info", "Hash kopyalandı", c.short)
	elseif name == ACT_WEB then
		local url = if state.web then parse.web_commit(state.web, c.hash) else nil
		if url then
			state.cx:open(url, if window then { window = window } else nil)
		else
			state.cx:toast("info", "Web adresi yok", "origin GitHub ya da GitLab değil.")
		end
	elseif name == ACT_BRANCH then
		create_branch(state, c, window)
	elseif name == ACT_AI then
		select(state, c.hash)
		explain(state, c)
	elseif string.sub(name, 1, #SWITCH) == SWITCH then
		local wanted = string.sub(name, #SWITCH + 1)
		for _, ref in c.refs do
			if ref.name == wanted and (ref.kind == "branch" or ref.kind == "remote") then
				switch_to(state, ref, window)
			end
		end
	elseif string.sub(name, 1, #JIRA) == JIRA then
		state.cx:open(`{state.cfg.jira_url}/browse/{string.sub(name, #JIRA + 1)}`, if window then { window = window } else nil)
	elseif string.sub(name, 1, #NOTE) == NOTE then
		local path = vault_note(state, `jira/{string.sub(name, #NOTE + 1)}.md`)
		if path then
			state.cx:open(path, if window then { window = window } else nil)
		end
	end
end

local function commit_menu(state: State, c: parse.Commit): { string }
	local menu = { ACT_COPY, ACT_WEB, ACT_BRANCH, ACT_AI }
	local locals: { [string]: boolean } = {}
	for _, ref in c.refs do
		if ref.kind == "branch" then
			locals[ref.name] = true
		end
	end
	for _, ref in c.refs do
		if ref.kind == "branch" and not ref.current then
			table.insert(menu, SWITCH .. ref.name)
		elseif ref.kind == "remote" then
			-- A remote branch whose local twin sits on the same commit is reached through the local one.
			local short = string.match(ref.name, "^[^/]+/(.+)$")
			if short and not locals[short] then
				table.insert(menu, SWITCH .. ref.name)
			end
		end
	end
	for _, key in jira_keys(state, c) do
		table.insert(menu, JIRA .. key)
		if vault_note(state, `jira/{key}.md`) then
			table.insert(menu, NOTE .. key)
		end
	end
	return menu
end

-- ---------------------------------------------------------------- view

-- Glyph → drawn piece. style.css draws each piece (lines, corners, the node) in the span's color and hides the
-- glyph; without the stylesheet the glyphs themselves still read as a `git log --graph`.
local PIECE: { [string]: string } = {
	["│"] = "v", ["┼"] = "v", ["─"] = "h", ["╯"] = "jr", ["╰"] = "jl", ["╮"] = "or", ["╭"] = "ol",
	["┤"] = "tr", ["├"] = "tl", ["●"] = "n", ["○"] = "n", ["◉"] = "n",
}

local function lane_spans(row: lanes.Row?): { Span | string }
	local out: { Span | string } = {}
	if row == nil then
		return out
	end
	for i, cell in row.cells do
		local tokens = { "gg", if i % 2 == 1 then "gg-s" else "gg-g" }
		local piece = PIECE[cell.ch]
		if piece then
			table.insert(tokens, "gg-" .. piece)
			table.insert(tokens, `gg-c{cell.color}`)
		end
		if piece == "n" then
			local flags: { { any } } = { { "t", row.top }, { "b", row.bottom }, { "l", row.left }, { "r", row.right } }
			for _, f in flags do
				if f[2] then
					table.insert(tokens, "gg-" .. (f[1] :: string))
				end
			end
			if cell.ch == "○" then
				table.insert(tokens, "gg-merge")
			elseif cell.ch == "◉" then
				table.insert(tokens, "gg-head")
			end
		end
		table.insert(out, ui.span(if cell.ch == " " then "\u{00A0}" else cell.ch, table.concat(tokens, " ")))
	end
	return out
end

local function ref_spans(c: parse.Commit): { Span | string }
	local out: { Span | string } = {}
	for _, ref in c.refs do
		if ref.kind ~= "head" then
			local label = if ref.kind == "tag" then "⌂ " .. ref.name elseif ref.kind == "remote" then "☁ " .. ref.name else ref.name
			local style = if ref.current then "key accent" elseif ref.kind == "remote" then "key muted" elseif ref.kind == "tag" then "key warning" else "key"
			table.insert(out, ui.span(label, style))
			table.insert(out, " ")
		end
	end
	return out
end

local function header(state: State): Node
	local spans: { Span | string } = {}
	if state.repo == nil then
		table.insert(spans, ui.span("Depo yok", "strong"))
	else
		table.insert(spans, ui.span(parse.base(state.repo), "strong"))
		local st = state.status
		if st then
			table.insert(spans, "  ")
			table.insert(spans, ui.span(if st.detached then "ayrık HEAD" else st.branch or "?", "accent"))
			if st.upstream and (st.ahead > 0 or st.behind > 0) then
				table.insert(spans, ui.span(`  ↑{st.ahead} ↓{st.behind}`, if st.behind > 0 then "warning" else "muted"))
			end
			if st.changed + st.conflicts > 0 then
				table.insert(spans, ui.span(`  ● {st.changed + st.conflicts} değişiklik`, if st.conflicts > 0 then "error" else "warning"))
			end
			if st.untracked > 0 then
				table.insert(spans, ui.span(`  +{st.untracked} izlenmeyen`, "muted"))
			end
		end
	end
	table.insert(spans, ui.span(if state.follow then "  · odağı izliyor" else "  · sabit", "muted"))
	if state.loading then
		table.insert(spans, ui.span(" · okunuyor", "muted"))
	elseif state.fetched then
		table.insert(spans, ui.span(" · " .. os.date("%H:%M", state.fetched), "muted"))
	end
	return with(ui.row({
		ui.text(spans),
		ui.button("", { icon = "sliders", keys = { "v" }, title = "Görünüm: dar ve geniş panede ne görünsün", size = "sm", variant = "quiet", on = state.settings, actions = { click = "settings" } }),
	}), { key = "head" })
end

local function toolbar(state: State): Node
	local buttons: { Node } = {
		ui.button("Depolar", { icon = "folder", keys = { "o" }, size = "sm", actions = { click = "repos" } }),
		ui.button(if state.follow then "Sabitle" else "Odağı izle", { icon = if state.follow then "pin" else "eye", keys = { "p" }, size = "sm", actions = { click = "pin" } }),
		ui.button("Uzak dallar", { icon = "cloud", keys = { "u" }, size = "sm", on = state.remotes, actions = { click = "remotes" } }),
		ui.button("Fetch", { icon = "download", keys = { "f" }, size = "sm", busy = state.busy == "fetch", disabled = state.repo == nil, actions = { click = "fetch" } }),
		ui.button("Yenile", { icon = "refresh", keys = { "r" }, size = "sm", disabled = state.repo == nil, actions = { click = "refresh" } }),
	}
	if state.repo and vault_note(state, `projects/{string.lower(parse.base(state.repo))}.md`) then
		table.insert(buttons, ui.button("Proje notu", { icon = "book", size = "sm", variant = "quiet", actions = { click = "project-note" } }))
	end
	return with(ui.row(buttons), { key = "toolbar" })
end

local function commit_table(state: State, vis: layout.Parts): Node
	local cols: { Col } = {}
	if vis.graph then
		table.insert(cols, { id = "graph", head = "", mono = true })
	end
	table.insert(cols, { id = "msg", head = "Mesaj", grow = 1 })
	if vis.author then
		table.insert(cols, { id = "author", head = "Yazar", priority = -1 })
	end
	if vis.age then
		table.insert(cols, { id = "age", head = "Zaman", align = "end", priority = -2 })
	end
	if vis.hash then
		table.insert(cols, { id = "hash", head = "Hash", mono = true, priority = -3 })
	end

	local rows: { TableRow } = {}
	local now = os.time()
	for i, c in state.commits do
		local msg: { Span | string } = if vis.refs then ref_spans(c) else {}
		table.insert(msg, c.subject)
		local cells: { Cell } = {}
		if vis.graph then
			table.insert(cells, lane_spans(state.rows[i]))
		end
		table.insert(cells, msg)
		if vis.author then
			table.insert(cells, c.author)
		end
		if vis.age then
			table.insert(cells, ui.span(parse.age(c.time, now), "muted"))
		end
		if vis.hash then
			table.insert(cells, ui.span(c.short, "muted"))
		end
		table.insert(rows, { id = c.hash, menu = commit_menu(state, c), cells = cells })
	end
	if state.more then
		local cells: { Cell } = {}
		for _, col in cols do
			table.insert(cells, if col.id == "msg" then { button = { text = `{PAGE} commit daha`, act = "more", icon = "chevron-down" } } else "")
		end
		table.insert(rows, { id = "more", cells = cells })
	end
	local empty = if state.repo == nil then "Bir terminale odaklan ya da Depolar'dan seç."
		elseif state.loading then "Geçmiş okunuyor…"
		else "Bu depoda commit yok."
	return with(ui.table(cols, rows, { selectable = true, selected = state.selected, empty = empty }), { key = "commits", role = "git-graph.commits" })
end

-- Görünüm: which parts show when the pane is narrow and when wide, and where narrow ends.
local function settings_layer(state: State, cols: number): Node
	local l = state.layout
	local mode = layout.mode(l, cols)
	local rows: { TableRow } = {}
	for _, part in layout.PARTS do
		local function toggle(which: string): Cell
			local on = (l :: any)[which][part.id] == true
			return { button = { text = if on then "Açık" else "Kapalı", act = `layout={which}:{part.id}`, variant = if on then "primary" else "default" } }
		end
		table.insert(rows, { id = part.id, cells = { part.label, toggle("narrow"), toggle("wide") } })
	end
	local children: { Node } = {
		ui.text({
			ui.span(`Pane şu an {cols} sütun: `, "muted"),
			ui.span(if mode == "narrow" then "dar" else "geniş", "strong"),
			ui.span(` · {l.threshold} sütunun altı dar sayılır`, "muted"),
		}),
		with(ui.row({
			ui.button(`−{layout.STEP}`, { size = "sm", disabled = l.threshold <= layout.MIN, actions = { click = "threshold=-1" } }),
			ui.button(`+{layout.STEP}`, { size = "sm", disabled = l.threshold >= layout.MAX, actions = { click = "threshold=1" } }),
			ui.button("Şu anki genişlik eşik olsun", { size = "sm", variant = "quiet", actions = { click = "threshold=here" } }),
		}), { key = "threshold" }),
		with(ui.table({
			{ id = "part", head = "Bölüm", grow = 1 },
			{ id = "narrow", head = "Dar pane", align = "center" },
			{ id = "wide", head = "Geniş pane", align = "center" },
		}, rows), { key = "parts" }),
		with(ui.row({
			ui.button("Yeni paneller de böyle açılsın", { icon = "check", size = "sm", actions = { click = "layout-default" } }),
			ui.button("Varsayılana dön", { size = "sm", variant = "quiet", actions = { click = "layout-reset" } }),
			ui.button("Kapat", { keys = { "esc" }, size = "sm", actions = { click = "settings" } }),
		}), { key = "actions" }),
	}
	return ui.col({ with(ui.card("Görünüm", children, { icon = "sliders" }), { key = "settings" }) })
end

local STATUS_TONE: { [string]: string } = { A = "success", D = "error", M = "warning", R = "info", C = "info", T = "muted" }

local function detail_card(state: State): Node?
	local c = find(state, state.selected)
	if c == nil then
		return nil
	end
	local d = state.details[c.hash]
	local children: { Node } = {}
	if d == nil then
		table.insert(children, ui.progress(nil, "Commit okunuyor"))
	else
		local rest = string.match(d.body, "^[^\n]*\n+(.+)$")
		if rest then
			table.insert(children, with(ui.text({ ui.span(rest, "muted") }), { key = "body" }))
		end
		local parents: { Node } = {}
		for _, p in d.parents do
			table.insert(parents, ui.button(string.sub(p, 1, 7), { size = "sm", variant = "quiet", actions = { click = "parent=" .. p } }))
		end
		for _, key in jira_keys(state, c) do
			table.insert(parents, ui.button(key, { icon = "ticket", size = "sm", actions = { click = "jira=" .. key } }))
		end
		local meta: { { Spans } } = {
			{ "Yazar", `{d.author} <{d.email}>` },
			{ "Tarih", os.date("%Y-%m-%d %H:%M", d.time) :: string },
		}
		if d.committer ~= d.author then
			table.insert(meta, { "Commit eden", d.committer })
		end
		table.insert(children, ui.kv(meta))
		if #parents > 0 then
			table.insert(children, with(ui.row(parents), { key = "parents" }))
		end
		local ai = state.ai[c.hash]
		if ai then
			table.insert(children, with(ui.section("AI özeti", { ui.md(ai) }), { key = "ai" }))
		elseif state.ai_busy[c.hash] then
			table.insert(children, ui.progress(nil, "AI açıklıyor"))
		else
			table.insert(children, ui.button(ACT_AI, { icon = "sparkles", keys = { "a" }, size = "sm", variant = "quiet", actions = { click = "ai" } }))
		end
		local files: { TableRow } = {}
		for i, f in d.files do
			table.insert(files, {
				id = `f{i}`,
				cells = {
					{ text = f.status, dot = STATUS_TONE[f.status] or "muted" },
					if f.old then { ui.span(f.old .. " → ", "muted"), ui.span(f.path) } else f.path,
				},
			})
		end
		table.insert(children, with(ui.table({
			{ id = "st", head = "" },
			{ id = "path", head = `Dosyalar ({#d.files}) · çift tık ya da enter: diff`, grow = 1, truncate = "start" },
		}, files, { selectable = true, selected = `f{state.file}`, empty = "Dosya değişikliği yok." }), { key = "files" }))
	end
	return with(ui.card({ ui.span(c.short, "mono"), ui.span(" " .. c.subject) }, children, {
		meta = parse.age(c.time, os.time()),
	}), { key = "detail" })
end

local function diff_layer(state: State): Node?
	local v = state.diff
	if v == nil then
		return nil
	end
	local children: { Node } = {}
	if v.err then
		table.insert(children, ui.text({ ui.span("⚠ " .. v.err, "warning") }))
	end
	if v.text then
		table.insert(children, if v.text == "" then ui.text({ ui.span("Bu dosyada metin farkı yok (ikili dosya ya da yalnız mod).", "muted") }) else ui.diff(v.text, v.path))
	elseif v.err == nil then
		table.insert(children, ui.progress(nil, "Diff okunuyor"))
	end
	table.insert(children, with(ui.button("Kapat", { keys = { "esc" }, size = "sm", actions = { click = "close" } }), { key = "close" }))
	return ui.col({ with(ui.card(v.path, children, { icon = "diff" }), { key = "diff" }) })
end

-- ---------------------------------------------------------------- block

local function tick(state: State)
	tern.timer(TICK_MS, function()
		if state.closed then
			return
		end
		take_answer(state)
		if state.follow then
			local f = tern.kv.get("focus")
			if type(f) == "table" and type(f.cwd) == "string" and f.cwd ~= "" and f.cwd ~= state.seen then
				state.seen = f.cwd
				open_dir(state, f.cwd, true)
			end
		end
		tick(state)
	end)
end

local function schedule_poll(state: State)
	tern.timer(POLL_MS, function()
		if state.closed then
			return
		end
		if not state.loading and state.busy == nil then
			poll(state, false)
		end
		schedule_poll(state)
	end)
end

local function move(state: State, delta: number)
	local n = #state.commits
	if n == 0 then
		return
	end
	local at = 1
	for i, c in state.commits do
		if c.hash == state.selected then
			at = i
		end
	end
	select(state, state.commits[math.clamp(at + delta, 1, n)].hash)
end

local function on_action(state: State, act: string, item: string?, window: string?)
	local name, value = string.match(act, "^([^=]+)=(.+)$")
	if name == "parent" and value then
		if find(state, value) then
			select(state, value)
		else
			state.cx:toast("info", "Ebeveyn yüklü sayfalarda değil", "Daha fazla commit yükleyin.")
		end
		return
	elseif name == "jira" and value then
		state.cx:open(`{state.cfg.jira_url}/browse/{value}`, if window then { window = window } else nil)
		return
	elseif name == "layout" and value then
		local mode, part = string.match(value, "^(%a+):(%a+)$")
		if mode and part then
			layout.toggle(state.layout, mode, part)
		end
		return
	elseif name == "threshold" and value then
		local t = if value == "here" then state.cx.cols else state.layout.threshold + (tonumber(value) or 0) * layout.STEP
		state.layout.threshold = math.clamp(t, layout.MIN, layout.MAX)
		return
	end
	if act == "settings" then
		state.settings = not state.settings
	elseif act == "layout-default" then
		tern.kv.set("layout-default", state.layout)
		state.cx:toast("success", "Yeni Git grafiği panelleri bu görünümle açılacak")
	elseif act == "layout-reset" then
		state.layout = layout.default()
	elseif act == "repos" then
		pick_repo(state, window)
	elseif act == "pin" then
		toggle_pin(state)
	elseif act == "remotes" then
		state.remotes = not state.remotes
		state.loading = true
		load_log(state, true)
	elseif act == "fetch" then
		fetch(state)
	elseif act == "refresh" then
		state.loading = true
		poll(state, true)
	elseif act == "more" then
		load_log(state, false)
	elseif act == "close" then
		state.diff = nil
	elseif act == "ai" then
		local c = find(state, state.selected)
		if c then
			explain(state, c)
		end
	elseif act == "project-note" and state.repo then
		local path = vault_note(state, `projects/{string.lower(parse.base(state.repo))}.md`)
		if path then
			state.cx:open(path, if window then { window = window } else nil)
		end
	elseif item then
		local c = find(state, item)
		if c then
			on_commit_action(state, act, c, window)
		end
	end
end

tern.block.define("graph", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local s = if type(saved) == "table" then saved else {}
		local state: State = {
			cx = cx, closed = false, cfg = config(),
			follow = true, repo = nil, seen = nil,
			remotes = s.remotes == true,
			commits = {}, rows = {}, more = false, loading = false, err = nil, note = nil,
			status = nil, sig = nil, head = nil, web = nil, fetched = nil,
			selected = if type(s.selected) == "string" then s.selected else nil,
			details = {}, file = 1, diff = nil, ai = {}, ai_busy = {}, busy = nil, asks = {}, gen = 0,
			layout = layout.sanitize(if type(s.layout) == "table" then s.layout else tern.kv.get("layout-default")),
			settings = false,
		}
		if args[1] == "--pick" then
			pick_repo(state, nil)
		elseif args[1] and args[1] ~= "" then
			open_dir(state, args[1], false)
		elseif type(s.repo) == "string" and s.follow == false then
			open_dir(state, s.repo, false)
		else
			local f = tern.kv.get("focus")
			local dir = if type(f) == "table" and type(f.cwd) == "string" and f.cwd ~= "" then f.cwd else cx.cwd
			if dir then
				state.seen = dir
				open_dir(state, dir, true)
			end
		end
		tick(state)
		schedule_poll(state)
		return state
	end,

	title = function(state: State): string?
		if state.repo == nil then
			return "Git"
		end
		local st = state.status
		local branch = if st and st.branch then " · " .. st.branch else ""
		return `Git · {parse.base(state.repo)}{branch}`
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local vis = layout.visible(state.layout, cx.cols)
		local children: { Node } = { header(state) }
		if vis.toolbar then
			table.insert(children, toolbar(state))
		end
		if state.note then
			table.insert(children, with(ui.text({ ui.span(state.note, "muted") }), { key = "note" }))
		end
		if state.err then
			table.insert(children, with(ui.text({ ui.span("⚠ " .. state.err, "warning") }), { key = "err" }))
		end
		table.insert(children, commit_table(state, vis))
		local detail = if vis.detail then detail_card(state) else nil
		return {
			main = ui.col(children),
			dock = if detail then ui.col({ detail }) else nil,
			layer = if state.settings then settings_layer(state, cx.cols) else diff_layer(state),
		}
	end,

	save = function(state: State): any
		return {
			repo = state.repo, follow = state.follow, remotes = state.remotes, selected = state.selected,
			layout = state.layout,
		}
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		local item = if type(ev.item) == "string" then ev.item else nil
		if ev.ev == "select" and item then
			if ev.id == "files" then
				state.file = tonumber(string.match(item, "^f(%d+)$")) or 1
			elseif item ~= "more" then
				select(state, item)
			end
		elseif ev.ev == "activate" and item then
			if ev.id == "files" then
				state.file = tonumber(string.match(item, "^f(%d+)$")) or 1
				open_diff(state)
			elseif item ~= "more" then
				select(state, item)
				state.file = 1
				open_diff(state)
			end
		elseif ev.ev == "action" and type(ev.act) == "string" then
			local act = ev.act :: string
			if type(ev.value) == "string" and not string.find(act, "=", 1, true) then
				act = act .. "=" .. ev.value
			end
			on_action(state, act, if ev.id == "commits" or item then item else nil, ev.window)
		end
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "escape" or key.name == "escape" or key.name == "esc" then
			if state.settings then
				state.settings = false
			elseif state.diff then
				state.diff = nil
			else
				return false
			end
		elseif k == "v" then
			state.settings = not state.settings
		elseif key.name == "down" or k == "j" then
			move(state, 1)
		elseif key.name == "up" or k == "k" then
			move(state, -1)
		elseif k == "]" or k == "[" then
			local d = if state.selected then state.details[state.selected] else nil
			if d == nil or #d.files == 0 then
				return false
			end
			state.file = math.clamp(state.file + (if k == "]" then 1 else -1), 1, #d.files)
			if state.diff then
				open_diff(state)
			end
		elseif key.name == "enter" then
			open_diff(state)
		elseif k == "r" then
			on_action(state, "refresh", nil, nil)
		elseif k == "f" then
			fetch(state)
		elseif k == "p" then
			toggle_pin(state)
		elseif k == "o" then
			pick_repo(state, nil)
		elseif k == "u" then
			on_action(state, "remotes", nil, nil)
		elseif k == "a" then
			on_action(state, "ai", nil, nil)
		elseif k == "c" and state.selected then
			on_action(state, ACT_COPY, state.selected, nil)
		elseif k == "w" and state.selected then
			on_action(state, ACT_WEB, state.selected, nil)
		elseif k == "b" and state.selected then
			on_action(state, ACT_BRANCH, state.selected, nil)
		else
			return false
		end
		return true
	end,
})
