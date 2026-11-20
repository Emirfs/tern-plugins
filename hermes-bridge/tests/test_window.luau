--!strict
-- window.luau end to end against window_stub: exports, context, spool and leader.
local check = require("./check")
local serde = require("@lune/serde")
local stub = require("./window_stub")

local ROOT = "hermes-bridge"

local function json(v: any): string
	return serde.encode("json", v)
end

-- Registration
do
	local h = stub.new(ROOT)
	local names = {}
	for name in h.exports do
		table.insert(names, name)
	end
	table.sort(names)
	check.same(names, { "agents_list", "esp_list", "esp_open", "hermes_ask", "hermes_kanban", "omp_start" }, "exports")
	for name, e in h.exports do
		check.truthy(string.match(name, "^[a-z][a-z0-9_]*$") and #name <= 24, `export name {name}`)
		check.truthy(#e.spec.sig <= 1024 and #e.spec.doc <= 1024, `export spec size {name}`)
	end
	check.truthy(h.dirs["C:\\spool\\done"] and h.dirs["C:\\spool\\failed"], "spool dirs made at load")
	check.truthy(h.commands.status ~= nil, "status command")
	local line = h.context(nil)
	check.truthy(type(line) == "string" and #line <= 400, "context line")
end

-- hermes_ask: argv, profile, reply and failure
do
	local h = stub.new(ROOT)
	local w = h.window()
	local ret, call = h.call("hermes_ask", w.cx, "what is the status?")
	check.eq(ret.wait, 120000, "answers later, within 120 s")
	check.same(h.procs[1].argv, { "hermes", "-z", "what is the status?" }, "hermes -z argv")
	check.eq(h.procs[1].opts.cwd, "C:\\home", "runs in home")
	h.finish({ stdout = "  All good.\n" })
	check.eq(call.replied, "All good.", "trimmed answer")

	_, call = h.call("hermes_ask", w.cx, "x", "kodcu")
	check.same(h.procs[1].argv, { "hermes", "-p", "kodcu", "-z", "x" }, "profile flag")
	h.finish({ status = 1, stderr = "boom" })
	check.eq(call.failed, "hermes -z exited 1: boom", "failure reason")

	check.truthy(not pcall(h.call, "hermes_ask", w.cx, "x", "a b"), "bad profile raises")
	check.truthy(not pcall(h.call, "hermes_ask", w.cx, "  "), "blank prompt raises")

	-- `hermes` off PATH: the install location is tried next.
	h.missing["hermes"] = true
	h.files["C:\\lad\\hermes\\bin\\hermes.exe"] = ""
	h.call("hermes_ask", w.cx, "y")
	check.eq(h.procs[1].argv[1], "C:\\lad\\hermes\\bin\\hermes.exe", "fallback executable")
	h.finish({ timed_out = true, status = -1 })
end

-- hermes_kanban: argv and JSON reply
do
	local h = stub.new(ROOT)
	local w = h.window()
	local _, call = h.call("hermes_kanban", w.cx, "Review the AC logs", nil, "kodcu")
	check.same(
		h.procs[1].argv,
		{ "hermes", "kanban", "create", "--json", "--created-by", "carly", "--assignee", "kodcu", "Review the AC logs" },
		"kanban argv without body"
	)
	h.finish({ stdout = json({ id = "t_12", status = "ready" }) })
	check.eq(call.replied.id, "t_12", "created task")

	_, call = h.call("hermes_kanban", w.cx, "T", "line 1\nline 2")
	check.same(
		h.procs[1].argv,
		{ "hermes", "kanban", "create", "--json", "--created-by", "carly", "--body", "line 1\nline 2", "T" },
		"kanban argv with body"
	)
	h.finish({ status = 2, stderr = "no such profile" })
	check.eq(call.failed, "hermes kanban create exited 2: no such profile", "kanban failure")
	check.truthy(not pcall(h.call, "hermes_kanban", w.cx, "T", nil, "x;y"), "bad assignee raises")
end

local DEVICES = {
	{ id = "fa-61d44cb4", name = "LG AC box", thread_id = 1232, session_key = "k1", session_id = "s1", platform = "telegram" },
	{ id = "fa-7ae9b284", name = "MHI VRF gateway", thread_id = 1409, session_key = "k2", platform = "telegram" },
}

-- esp_list fills the shared cache and the context line; esp_open opens, then focuses
do
	local h = stub.new(ROOT)
	local w = h.window()
	local _, call = h.call("esp_list", w.cx)
	check.same(h.procs[1].argv, { "hermes", "tern", "--list-devices" }, "list argv")
	h.finish({ stdout = json(DEVICES) })
	check.eq(#call.replied, 2, "devices replied")
	check.eq(#h.kv.devices.list, 2, "devices stored for every window")
	local line = h.context(nil)
	check.truthy(string.find(line, "LG AC box [fa-61d44cb4]", 1, true), "context names devices")

	local r = h.call("esp_open", w.cx, "AC")
	check.eq(r.device, "fa-61d44cb4", "resolved device")
	check.eq(r.opened, true, "opened a tab")
	local esp = w.sessions[2]
	check.eq(esp.name, "ESP", "ESP session created")
	local tabs = {}
	for _, t in w.tabs do
		if t.session == esp.id then
			table.insert(tabs, t)
		end
	end
	check.eq(#tabs, 1, "starting shell tab closed")
	check.eq(tabs[1].name, "LG AC box", "tab named after the device")
	check.eq(tabs[1].command, "hermes tern --device fa-61d44cb4", "tab command")
	check.eq(tabs[1].color, "teal", "tab colored")

	local again = h.call("esp_open", w.cx, "fa-61d44cb4")
	check.eq(again.opened, false, "second open focuses")
	check.eq(w.focused, tabs[1].pane, "focused the device tab")

	local other = h.call("esp_open", w.cx, "MHI")
	check.eq(other.opened, true, "another device: a new tab")
	local count = 0
	for _, t in w.tabs do
		if t.session == esp.id then
			count += 1
		end
	end
	check.eq(count, 2, "two device tabs in ESP")

	-- List failure: the error is kept, the last good list too.
	h.call("esp_list", w.cx)
	h.finish({ status = 2, stderr = "unrecognized arguments: --list-devices" })
	check.truthy(string.find(h.kv.devices.error, "unrecognized", 1, true), "error stored")
	check.eq(#h.kv.devices.list, 2, "last good list kept")
end

-- omp_start and agents_list
do
	local h = stub.new(ROOT)
	local w = h.window()
	local r = h.call("omp_start", w.cx, "run the tests", "C:\\repo")
	check.eq(r.pane, 42, "agent pane")
	check.same(w.started[1], { prompt = "run the tests", cwd = "C:\\repo", how = "tab" }, "start opts")
	h.call("omp_start", w.cx, "p", nil, "omp --profile work")
	check.same(w.started[2], { prompt = "p", cwd = "C:\\home", command = "omp --profile work", how = "tab" }, "default cwd, command")
	w.agents_list = { { pane = 5, cwd = "C:\\", state = "idle", command = "omp", last_message = "ok" } }
	local list = h.call("agents_list", w.cx)
	check.eq(list[1].pane, 5, "agents listed")
end

-- Spool: the leader runs jobs, records them; other files are left alone
do
	local h = stub.new(ROOT)
	local w = h.window()
	local function job(name: string, body: any)
		h.files["C:\\spool\\" .. name] = json(body)
	end
	job("20260101T000000-000-a.json", { v = 1, id = "a", kind = "notify", text = "hello", from = "hermes" })
	job("20260101T000000-001-b.json", { v = 1, id = "b", kind = "omp", prompt = "say hi", cwd = "C:\\lab" })
	job("20260101T000000-002-c.json", { v = 1, id = "c", kind = "carly", text = "tidy up the window", from = "omp" })
	job("20260101T000000-003-d.json", { v = 1, id = "d", kind = "launch_missiles" })
	job("20260101T000000-004-e.json", { v = 1, id = "e", kind = "esp_open", device = "fa-61d44cb4" })
	h.files["C:\\spool\\.20260101T000000-005-f.tmp"] = "{"
	h.files["C:\\spool\\20260101T000000-006-g.json"] = "{not json"

	h.fire(w.cx)

	check.eq(h.kv.leader.key, "", "took the lead")
	check.eq(w.toasts[1].text, "hello", "notify shown")
	check.eq(w.toasts[1].sub, "tern-bridge · hermes", "notify sub line")
	check.same(w.started[1], { prompt = "say hi", cwd = "C:\\lab", how = "tab" }, "omp started")
	check.eq(w.asked[1], "[omp via tern-bridge] tidy up the window", "Carly asked")
	check.eq(w.tabs[#w.tabs].command, "hermes tern --device fa-61d44cb4", "device tab opened")

	for _, n in { "a", "b", "c", "e" } do
		local done = h.files[`C:\\spool\\done\\20260101T000000-00{({ a = 0, b = 1, c = 2, e = 4 })[n]}-{n}.json`]
		check.truthy(done ~= nil, `job {n} recorded in done`)
	end
	local d = serde.decode("json", h.files["C:\\spool\\failed\\20260101T000000-003-d.json"])
	check.eq(d.error, "unknown kind launch_missiles", "bad kind failed with reason")
	local g = serde.decode("json", h.files["C:\\spool\\failed\\20260101T000000-006-g.json"])
	check.eq(g.error, "invalid JSON", "bad JSON failed")
	check.eq(h.files["C:\\spool\\20260101T000000-000-a.json"], nil, "job claimed")
	check.truthy(h.files["C:\\spool\\.20260101T000000-005-f.tmp"] ~= nil, "tmp file left alone")
	local b = serde.decode("json", h.files["C:\\spool\\done\\20260101T000000-001-b.json"])
	check.eq(b.result.pane, 42, "outcome recorded")

	-- A job whose action raises is still claimed, and recorded as failed.
	w.cx.agents.start = function()
		error("agent settings missing")
	end
	job("20260101T000001-000-h.json", { v = 1, id = "h", kind = "omp", prompt = "x" })
	h.fire(w.cx)
	local hrec = serde.decode("json", h.files["C:\\spool\\failed\\20260101T000001-000-h.json"])
	check.truthy(string.find(hrec.error, "agent settings missing", 1, true), "raised action failed")
	check.eq(h.files["C:\\spool\\20260101T000001-000-h.json"], nil, "raised job claimed")
end

-- read: a new titled tab in the user's current session, once per key, the user's focus put back
do
	local h = stub.new(ROOT)
	local w = h.window()
	w.focused = 100
	local function job(name: string, body: any)
		h.files["C:\\spool\\" .. name] = json(body)
	end
	h.files["C:\\r\\daily.md"] = "# Daily\n"
	job("20260101T000000-000-a.json", { v = 1, id = "a", kind = "read", path = "C:\\r\\daily.md", title = "🧠 Daily summary 19.11", key = "daily-2026-11-19", from = "hafiza" })
	job("20260101T000000-001-b.json", { v = 1, id = "b", kind = "read", path = "C:\\r\\daily.md", title = "again", key = "daily-2026-11-19" })
	job("20260101T000000-002-c.json", { v = 1, id = "c", kind = "read", path = "C:\\r\\none.md", title = "x", key = "missing" })
	local sessions_before = #w.sessions
	h.fire(w.cx)

	check.eq(#w.sessions, sessions_before, "no extra session created")
	local last = w.tabs[#w.tabs]
	check.eq(last.session, w.current, "opened in the user's current session")
	check.eq(last.doc, "C:\\r\\daily.md", "document opened")
	check.eq(last.how, "tab", "as a new tab")
	check.eq(last.name, "🧠 Daily summary 19.11", "tab titled")
	check.eq(w.focused, 100, "user's focus put back")
	check.eq(w.toasts[1].text, "Reading: 🧠 Daily summary 19.11", "info toast")
	check.eq(w.toasts[1].sub, "tern-bridge · hafiza", "toast sub line")
	check.same(h.kv.read_seen, { "daily-2026-11-19" }, "key remembered")
	local b = serde.decode("json", h.files["C:\\spool\\done\\20260101T000000-001-b.json"])
	check.eq(b.result.duplicate, true, "same key not opened again")
	local c = serde.decode("json", h.files["C:\\spool\\failed\\20260101T000000-002-c.json"])
	check.truthy(string.find(c.error, "no such file", 1, true), "missing file failed")
	check.same(h.kv.read_seen, { "daily-2026-11-19" }, "failed key not remembered")
end

-- Another window holds a fresh lead: this one leaves the spool alone
do
	local h = stub.new(ROOT)
	local w = h.window()
	h.kv.leader = { key = "other", at = os.time() }
	h.files["C:\\spool\\20260101T000000-000-a.json"] = json({ v = 1, id = "a", kind = "notify", text = "x" })
	h.fire(w.cx)
	check.truthy(h.files["C:\\spool\\20260101T000000-000-a.json"] ~= nil, "follower leaves jobs")
	check.eq(#w.toasts, 0, "follower runs nothing")
	-- Unload hands over only a lead it holds.
	h.handlers.unload(w.cx)
	check.eq(h.kv.leader.key, "other", "unload keeps another's lead")
end

return nil
