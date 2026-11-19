--!strict
-- Window half: Carly exports and context, the spool consumer for `tern-bridge` jobs and the status
-- refresher. Everything runs here because `cx.agents`, `cx:ask_carly` and `tern.carly` are window only.
--
-- One window consumes the spool (a heartbeat in `tern.kv` elects it); every window keeps its own copy of
-- the context line, rebuilt each minute from `gateway_state.json` and the device list the leader stores.

local bridge = require("./lib/bridge")

type Device = bridge.Device
type Job = bridge.Job

local POLL_MS = 2000
local STATUS_MS = 60 * 1000
-- The leader lists devices (a `hermes` start, a few seconds of CPU) this often.
local DEVICES_MAX_AGE_S = 5 * 60
local LEADER_STALE_S = 10
local LEADER_BEAT_S = 4
local HERMES_ASK_TIMEOUT_MS = 115 * 1000
local ASK_WAIT_MS = 120 * 1000
local CLI_TIMEOUT_MS = 60 * 1000
local CLI_WAIT_MS = 65 * 1000
local MAX_JOB_BYTES = 256 * 1024
local MAX_JOBS_PER_TICK = 8
local KEEP_RECORDS = 200
local ESP_SESSION = "ESP"
local READ_SEEN_KEY = "read_seen"
local READ_SEEN_MAX = 500
local LEADER_KEY = "leader"
local DEVICES_KEY = "devices"
local ID = "hermes-bridge"

local function join(a: string, b: string): string
	local last = string.sub(a, -1)
	if last == "\\" or last == "/" then
		return a .. b
	end
	return a .. (if tern.runtime.os == "windows" then "\\" else "/") .. b
end

local function home(): string
	return tern.getenv("USERPROFILE") or tern.getenv("HOME") or "~"
end

local SPOOL = tern.getenv("TERN_BRIDGE_SPOOL") or join(tern.plugin.data, "spool")
local DONE = join(SPOOL, "done")
local FAILED = join(SPOOL, "failed")
pcall(tern.fs.mkdir, DONE)
pcall(tern.fs.mkdir, FAILED)

local function hermes_home(): string?
	local env = tern.getenv("HERMES_HOME")
	if env and env ~= "" then
		return env
	end
	local lad = tern.getenv("LOCALAPPDATA")
	if lad then
		return join(lad, "hermes")
	end
	local h = tern.getenv("HOME")
	return if h then join(h, ".hermes") else nil
end

-- The daemon's PATH may be narrower than a shell's: the name first, then where Hermes installs itself.
local function hermes_candidates(): { string }
	local list = { "hermes" }
	local lad = tern.getenv("LOCALAPPDATA")
	if lad then
		local exe = join(lad, "hermes\\bin\\hermes.exe")
		if tern.fs.exists(exe) then
			table.insert(list, exe)
		end
	end
	return list
end

local function tail(s: string, n: number): string
	if #s <= n then
		return s
	end
	return "…" .. string.sub(s, -n)
end

local function trim(s: string): string
	local s1 = string.gsub(s, "^%s+", "")
	local s2 = string.gsub(s1, "%s+$", "")
	return s2
end

--- Runs `hermes <args>`; `done` gets stdout, or nil and why it failed (`what` names the run in errors).
local function run_hermes(what: string, args: { string }, timeout: number, done: (string?, string?) -> ())
	local last = "hermes was not found on PATH"
	for _, exe in hermes_candidates() do
		local argv = { exe }
		for _, a in args do
			table.insert(argv, a)
		end
		local ok, err = pcall(function()
			tern.process.run(
				argv,
				{ timeout_ms = timeout, cwd = home(), env = { NO_COLOR = "1", PYTHONIOENCODING = "utf-8" } },
				function(r: ProcessResult, _)
					if r.timed_out then
						done(nil, `{what} timed out after {math.floor(timeout / 1000)} s`)
					elseif r.status ~= 0 then
						local why = trim(r.stderr)
						if why == "" then
							why = trim(r.stdout)
						end
						done(nil, `{what} exited {r.status}: {tail(why, 1500)}`)
					else
						done(r.stdout, nil)
					end
				end
			)
		end)
		if ok then
			return
		end
		last = tostring(err)
	end
	done(nil, last)
end

---------------------------------------------------------------------------
-- Status: gateway state and devices, for the Carly context line

local devices: { Device }? = nil
local devices_err: string? = nil
local listing = false
local context_line = "Hermes bridge starting."

local function read_gateway(): any
	local dir = hermes_home()
	if not dir then
		return nil
	end
	local ok, text = pcall(tern.fs.read, join(dir, "gateway_state.json"), 1024 * 1024)
	if not ok then
		return nil
	end
	local okd, data = pcall(tern.json.decode, text)
	return if okd then data else nil
end

local function load_devices()
	local ok, entry = pcall(tern.kv.get, DEVICES_KEY)
	if ok and type(entry) == "table" then
		local list = if entry.list ~= nil then bridge.parse_devices(entry.list) else nil
		devices = list
		devices_err = if type(entry.error) == "string" then entry.error else nil
	end
end

local function rebuild_context()
	context_line = bridge.status_line(read_gateway(), devices, devices_err)
end

--- Lists devices with `hermes tern --list-devices` (C1), stores them for every window and calls `done`.
local function list_devices(done: ((list: { Device }?, err: string?) -> ())?)
	if listing and not done then
		return
	end
	listing = true
	run_hermes("hermes tern --list-devices", { "tern", "--list-devices" }, CLI_TIMEOUT_MS, function(out: string?, err: string?)
		listing = false
		local list: { Device }? = nil
		if out then
			local ok, raw = pcall(tern.json.decode, out)
			if ok then
				list, err = bridge.parse_devices(raw)
			else
				err = "hermes tern --list-devices printed no JSON (does this Hermes have the --list-devices flag?)"
			end
		end
		local entry: { [string]: any } = { at = os.time() }
		if list then
			entry.list = tern.json.array(list)
			devices, devices_err = list, nil
		else
			entry.error = bridge.clip(bridge.last_line(err or "unknown error"), 200)
			-- Keep the last good list; say why it may be stale.
			entry.list = if devices then tern.json.array(devices) else nil
			devices_err = entry.error
		end
		pcall(tern.kv.set, DEVICES_KEY, entry)
		rebuild_context()
		if done then
			done(list, err)
		end
	end)
end

---------------------------------------------------------------------------
-- Actions shared by the exports and the spool

--- Opens or focuses the device's tab in session "ESP" (C1 layout: one tab per device running
--- `hermes tern --device <id>`, named after the device).
local function open_device(cx: WindowCx, query: string): { [string]: any }
	local d = bridge.match_device(devices, query)
	local id = if d then d.id else query
	local name = if d then d.name else query
	local session = cx.session:find_session(ESP_SESSION)
	local stray: { number } = {}
	if session then
		cx.sessions:switch(session)
		local tab = bridge.find_tab(cx.session:tabs(), session, id, name)
		if tab then
			cx.layout:focus(tab.pane)
			return { device = id, name = name, tab = tab.id, pane = tab.pane, opened = false }
		end
	else
		local created = cx.sessions:create({ name = ESP_SESSION, cwd = home() })
		session = created.id
		-- The new session's starting shell tab goes once the device tab stands.
		for _, tab in cx.session:tabs() do
			if tab.session == created.id then
				table.insert(stray, tab.pane)
			end
		end
	end
	local tab, err = cx.layout:tab({ name = name, cwd = home(), launch = { command = bridge.device_command(id) } })
	if not tab then
		error(err or "could not open the device tab")
	end
	pcall(function()
		cx.layout:color_tab(tab, "teal")
	end)
	for _, pane in stray do
		pcall(function()
			cx.layout:close(pane)
		end)
	end
	return { device = id, name = name, tab = tab, opened = true, known = d ~= nil }
end

--- Opens a Markdown file as a new titled tab of the session the user is looking at, once per key (bounded
--- seen-set in kv). `cx.docs:open` focuses what it opens, so the user's focused pane is put back afterwards:
--- the tab waits in the tab bar (blue) until read.
local function open_reading(cx: WindowCx, job: Job): { [string]: any }
	local key, title, path = job.key :: string, job.title :: string, job.path :: string
	local seen = bridge.remember(tern.kv.get(READ_SEEN_KEY), key, READ_SEEN_MAX)
	if not seen then
		return { key = key, opened = false, duplicate = true }
	end
	if not tern.fs.exists(path) then
		error(`no such file {path}`)
	end
	local prev_pane = cx.session:focused()
	local pane = cx.docs:open(path, { how = "tab" })
	local tab = cx.session:tab_of(pane)
	if not tab then
		error("the document opened outside a tab")
	end
	local t = tab :: number
	cx.layout:name_tab(t, title)
	pcall(function()
		cx.layout:color_tab(t, "blue")
	end)
	if prev_pane then
		pcall(function()
			cx.layout:focus(prev_pane)
		end)
	end
	tern.kv.set(READ_SEEN_KEY, seen)
	cx:toast("info", `Okuma: {title}`, if job.from then `tern-bridge · {job.from}` else "tern-bridge")
	return { key = key, opened = true, tab = t, pane = pane }
end

local function start_omp(cx: WindowCx, prompt: string, cwd: string?, command: string?, how: string?): number
	return cx.agents:start({
		prompt = prompt,
		cwd = cwd or home(),
		command = command,
		how = (how or "tab") :: any,
	})
end

local function run_job(cx: WindowCx, job: Job): any
	if job.kind == "carly" then
		local text = job.text :: string
		if job.from then
			text = `[{job.from} via tern-bridge] {text}`
		end
		cx:ask_carly(text)
		return { asked = true }
	elseif job.kind == "omp" then
		return { pane = start_omp(cx, job.prompt :: string, job.cwd, job.command, job.how) }
	elseif job.kind == "esp_open" then
		return open_device(cx, job.device :: string)
	elseif job.kind == "notify" then
		local sub = job.title or (if job.from then `tern-bridge · {job.from}` else "tern-bridge")
		cx:toast((job.level or "info") :: any, job.text :: string, sub)
		return { shown = true }
	elseif job.kind == "read" then
		return open_reading(cx, job)
	end
	error(`unknown kind {job.kind}`)
end

---------------------------------------------------------------------------
-- Spool: `tern-bridge` writes <spool>/<id>.json (tmp + rename); the leader window claims each by removing
-- it, runs it and records the outcome in done/ or failed/.

local my_key: string? = nil

local function record(dir: string, name: string, entry: { [string]: any })
	entry.processed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	entry.window = my_key
	local ok, err = pcall(function()
		tern.fs.write(join(dir, name), tern.json.encode(entry, true))
	end)
	if not ok then
		tern.log.warn("hermes-bridge: could not record", name, err)
	end
	local okl, names = pcall(tern.fs.list, dir)
	if okl then
		for _, old in bridge.prune(names, KEEP_RECORDS) do
			pcall(tern.fs.remove, join(dir, old))
		end
	end
end

local function handle(cx: WindowCx, name: string)
	local path = join(SPOOL, name)
	local raw: any = nil
	local reason: string? = nil
	local okr, text = pcall(tern.fs.read, path, MAX_JOB_BYTES)
	if not okr then
		reason = `unreadable: {text}`
	else
		local okd, decoded = pcall(tern.json.decode, text)
		if okd then
			raw = decoded
		else
			reason = "invalid JSON"
		end
	end
	-- Claim it first: a job runs at most once, even when it raises.
	local okrm, rmerr = pcall(function()
		tern.fs.remove(path)
	end)
	if not okrm then
		tern.log.warn("hermes-bridge: could not claim", name, rmerr)
		return
	end
	local job: Job? = nil
	if not reason then
		job, reason = bridge.validate(raw)
	end
	if job then
		local okx, result = pcall(run_job, cx, job)
		if okx then
			record(DONE, name, { ok = true, job = job, result = result })
			return
		end
		reason = tostring(result)
	end
	record(FAILED, name, { ok = false, job = raw or { file = name }, error = reason })
	tern.log.warn("hermes-bridge: job failed", name, reason)
end

local function drain(cx: WindowCx)
	local ok, names = pcall(tern.fs.list, SPOOL)
	if not ok then
		pcall(tern.fs.mkdir, DONE)
		pcall(tern.fs.mkdir, FAILED)
		return
	end
	local jobs: { string } = {}
	for _, name in names do
		if bridge.is_job_file(name) then
			table.insert(jobs, name)
		end
	end
	table.sort(jobs)
	for i, name in jobs do
		if i > MAX_JOBS_PER_TICK then
			break
		end
		handle(cx, name)
	end
end

local function leading(cx: WindowCx): boolean
	my_key = cx:window_key()
	local entry = tern.kv.get(LEADER_KEY)
	local lead, write = bridge.leader(entry, my_key :: string, os.time(), LEADER_STALE_S, LEADER_BEAT_S)
	if write then
		tern.kv.set(LEADER_KEY, { key = my_key, at = os.time() })
	end
	return lead
end

local function poll()
	tern.timer(POLL_MS, function(cx: WindowCx?)
		poll()
		if not cx then
			return
		end
		local ok, err = pcall(function()
			if leading(cx) then
				drain(cx)
			end
		end)
		if not ok then
			tern.log.warn("hermes-bridge: spool poll failed", err)
		end
	end)
end

local function refresh_status(cx: WindowCx?)
	load_devices()
	rebuild_context()
	if not cx then
		return
	end
	local ok, lead = pcall(leading, cx)
	if not (ok and lead) then
		return
	end
	local entry = tern.kv.get(DEVICES_KEY)
	local at = if type(entry) == "table" and type(entry.at) == "number" then entry.at else 0
	if os.time() - at >= DEVICES_MAX_AGE_S then
		list_devices(nil)
	end
end

local function status_tick()
	tern.timer(STATUS_MS, function(cx: WindowCx?)
		status_tick()
		local ok, err = pcall(function()
			refresh_status(cx)
		end)
		if not ok then
			tern.log.warn("hermes-bridge: status refresh failed", err)
		end
	end)
end

---------------------------------------------------------------------------
-- Carly

-- Budget 4 ms: the line is prepared by the timers, this only hands it over.
tern.carly.context(function(_cx: WindowCx): string?
	return context_line
end)

local function define(name: string, sig: string, doc: string, fn: (args: { any }, cx: WindowCx, call: ExportCall) -> any)
	tern.carly.export(name, { sig = sig, doc = doc }, function(...: any): any
		local args, cx, call = bridge.split_args(...)
		return fn(args, cx, call)
	end)
end

local function need_string(v: any, what: string): string
	if type(v) ~= "string" or string.match(v, "^%s*$") then
		error(`{what} must be a non-empty string`)
	end
	return v
end

define(
	"hermes_ask",
	"hermes_ask(prompt: string, profile: string?) -> string",
	"Asks Hermes (the user's always-on agent that runs the Telegram bot and the ESP field devices) one question "
		.. "with `hermes -z` and returns its final answer text. profile picks a Hermes profile (kodcu, mimar, …; "
		.. "default: the main one). Takes up to ~2 minutes. One-shot runs deny commands that need approval "
		.. "(approvals.single_query_mode defaults to deny); never ask it to message people or drive devices without the user's explicit approval.",
	function(args, _cx, call)
		local prompt = need_string(args[1], "prompt")
		local argv: { string } = {}
		if args[2] ~= nil then
			if not bridge.valid_profile(args[2]) then
				error("profile must be a Hermes profile name")
			end
			table.insert(argv, "-p")
			table.insert(argv, args[2])
		end
		table.insert(argv, "-z")
		table.insert(argv, prompt)
		run_hermes("hermes -z", argv, HERMES_ASK_TIMEOUT_MS, function(out, err)
			if out then
				call:reply(trim(out))
			else
				call:fail(err or "hermes failed")
			end
		end)
		return call:wait(ASK_WAIT_MS)
	end
)

define(
	"hermes_kanban",
	"hermes_kanban(title: string, body: string?, assignee: string?) -> table",
	"Creates a card on the Hermes kanban board (`hermes kanban create --json`) and returns the created task. "
		.. "assignee is a Hermes profile name (kodcu, mimar, elestirmen, jira-mentor, antigravity-inceleme); "
		.. "an assigned card is dispatched to that profile automatically. Hermes itself notifies the user's "
		.. "Telegram Kanban topic, so do not announce it separately.",
	function(args, _cx, call)
		local title = need_string(args[1], "title")
		local argv: { string } = { "kanban", "create", "--json", "--created-by", "carly" }
		if args[2] ~= nil and args[2] ~= "" then
			table.insert(argv, "--body")
			table.insert(argv, need_string(args[2], "body"))
		end
		if args[3] ~= nil and args[3] ~= "" then
			if not bridge.valid_profile(args[3]) then
				error("assignee must be a Hermes profile name")
			end
			table.insert(argv, "--assignee")
			table.insert(argv, args[3])
		end
		table.insert(argv, title)
		run_hermes("hermes kanban create", argv, CLI_TIMEOUT_MS, function(out, err)
			if not out then
				call:fail(err or "hermes kanban failed")
				return
			end
			local ok, data = pcall(tern.json.decode, out)
			call:reply(if ok then data else trim(out))
		end)
		return call:wait(CLI_WAIT_MS)
	end
)

define(
	"esp_list",
	"esp_list() -> {{id: string, name: string, thread_id: number?, session_key: string?, session_id: string?, platform: string?}}",
	"The ESP field devices Hermes manages, each with its Telegram topic and current Hermes session "
		.. "(session_id nil: no open session), from `hermes tern --list-devices`.",
	function(_args, _cx, call)
		list_devices(function(list, err)
			if list then
				call:reply(tern.json.array(list))
			else
				call:fail(err or "could not list devices")
			end
		end)
		return call:wait(CLI_WAIT_MS)
	end
)

define(
	"esp_open",
	"esp_open(device: string) -> {device: string, name: string, tab: number, opened: boolean}",
	"Opens (or focuses) the device's live Hermes conversation as a tab in the Tern session \"ESP\": the tab runs "
		.. "`hermes tern --device <id>`, showing what Hermes does for that device, and the user can type into it. "
		.. "device is an id (fa-…), alias or part of the name.",
	function(args, cx, _call)
		return open_device(cx, need_string(args[1], "device"))
	end
)

define(
	"omp_start",
	"omp_start(prompt: string, cwd: string?, command: string?) -> {pane: number}",
	"Starts a coding agent (omp, per the agent settings; command overrides, e.g. \"omp --profile work\") in a new "
		.. "tab in cwd (default: home) with prompt as its first message. Returns its pane for cx.agents calls.",
	function(args, cx, _call)
		local prompt = need_string(args[1], "prompt")
		local cwd = if args[2] ~= nil then need_string(args[2], "cwd") else nil
		local command = if args[3] ~= nil then need_string(args[3], "command") else nil
		return { pane = start_omp(cx, prompt, cwd, command, "tab") }
	end
)

define(
	"agents_list",
	"agents_list() -> {{pane: number, command: string?, cwd: string, state: string, last_message: string?}}",
	"Every agent block (omp, …) across sessions with its state and the start of its last message.",
	function(_args, cx, _call)
		return tern.json.array(bridge.compact_agents(cx.agents:list()))
	end
)

---------------------------------------------------------------------------
-- Palette

tern.command({
	id = "status",
	title = "Hermes köprüsü: durum",
	icon = "sparkle",
	run = function(cx: WindowCx)
		local pending, failed = 0, 0
		local ok, names = pcall(tern.fs.list, SPOOL)
		if ok then
			for _, n in names do
				if bridge.is_job_file(n) then
					pending += 1
				end
			end
		end
		local okf, fnames = pcall(tern.fs.list, FAILED)
		if okf then
			for _, n in fnames do
				if bridge.is_job_file(n) then
					failed += 1
				end
			end
		end
		cx:toast("info", context_line, `kuyruk: {pending} bekleyen, {failed} başarısız · {SPOOL}`)
	end,
})

---------------------------------------------------------------------------
-- Start

tern.on("unload", function(_cx)
	-- Hand the spool over at once instead of after the heartbeat goes stale.
	local ok, entry = pcall(tern.kv.get, LEADER_KEY)
	if ok and my_key and type(entry) == "table" and entry.key == my_key then
		pcall(tern.kv.set, LEADER_KEY, nil)
	end
end)

-- A plugin loaded into an open window gets no window_start: start on load too.
load_devices()
rebuild_context()
tern.timer(0, function(cx: WindowCx?)
	pcall(refresh_status, cx)
end)
poll()
status_tick()

tern.log.info(ID, "spool", SPOOL)
