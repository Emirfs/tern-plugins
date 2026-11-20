--!strict
local bridge = require("../lib/bridge")
local check = require("./check")

-- validate: kinds and their required fields
do
	local job, err = bridge.validate({ v = 1, id = "a", kind = "notify", text = "hi" })
	check.eq(err, nil, "notify valid")
	check.eq((job :: any).level, "info", "notify level defaults to info")

	job, err = bridge.validate({ v = 1, id = "a", kind = "omp", prompt = "say hi", cwd = "C:\\x" })
	check.eq(err, nil, "omp valid")
	check.eq((job :: any).how, "tab", "omp how defaults to tab")

	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "omp", prompt = "  " })), "omp job needs a prompt", "blank prompt")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "carly" })), "carly job needs text", "carly without text")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "esp_open" })), "esp_open job needs a device", "esp without device")
	check.eq(select(2, bridge.validate({ v = 2, id = "a", kind = "notify", text = "x" })), "unsupported job version 2", "version")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "rm" })), "unknown kind rm", "unknown kind")
	check.eq(select(2, bridge.validate({ v = 1, kind = "notify", text = "x" })), "job has no id", "no id")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "notify", text = 5 })), "text must be a string", "typed field")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "notify", text = "x", level = "loud" })), "unknown level loud", "level")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "omp", prompt = "x", how = "float" })), "unknown how float", "how")
	check.eq(select(2, bridge.validate("nope")), "job is not a JSON object", "not an object")
	check.eq(
		select(2, bridge.validate({ v = 1, id = "a", kind = "carly", text = string.rep("x", 8001) })),
		"text is longer than 8000 bytes",
		"text limit"
	)
end

-- read jobs and the seen-set
do
	local job, err = bridge.validate({ v = 1, id = "a", kind = "read", path = "C:\\r\\x.md", title = "T", key = "k" })
	check.eq(err, nil, "read valid")
	check.eq((job :: any).key, "k", "read keeps key")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "read", title = "T", key = "k" })), "read job needs a path", "read without path")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "read", path = "p", key = "k" })), "read job needs a title", "read without title")
	check.eq(select(2, bridge.validate({ v = 1, id = "a", kind = "read", path = "p", title = "T", key = " " })), "read job needs a key", "blank key")
	check.eq(
		select(2, bridge.validate({ v = 1, id = "a", kind = "read", path = "p", title = "T", key = string.rep("k", 201) })),
		"key is longer than 200 bytes",
		"key limit"
	)
	check.same(bridge.remember(nil, "a", 3), { "a" }, "remember into nothing")
	check.eq(bridge.remember({ "a", "b" }, "a", 3), nil, "seen key")
	check.same(bridge.remember({ "a", "b", "c" }, "d", 3), { "b", "c", "d" }, "bounded seen-set")
end

-- spool file names and pruning
do
	check.eq(bridge.is_job_file("20261117T101010-001-abc.json"), true, "job file")
	check.eq(bridge.is_job_file(".20261117T101010-001-abc.tmp"), false, "tmp file")
	check.eq(bridge.is_job_file(".x.json"), false, "hidden json")
	check.eq(bridge.is_job_file("done"), false, "directory")
	check.same(bridge.prune({ "c.json", "a.json", "b.json", "x.tmp" }, 1), { "a.json", "b.json" }, "prune keeps newest")
	check.same(bridge.prune({ "a.json" }, 5), {}, "prune under the cap")
end

-- leader election
do
	local lead, write = bridge.leader(nil, "w1", 100, 10, 4)
	check.eq(lead and write, true, "no leader: take it")
	lead, write = bridge.leader({ key = "w2", at = 95 }, "w1", 100, 10, 4)
	check.eq(lead or write, false, "fresh other leader: stay out")
	lead, write = bridge.leader({ key = "w2", at = 80 }, "w1", 100, 10, 4)
	check.eq(lead and write, true, "stale other leader: take over")
	lead, write = bridge.leader({ key = "w1", at = 98 }, "w1", 100, 10, 4)
	check.eq(lead, true, "own fresh entry leads")
	check.eq(write, false, "own fresh entry: no write")
	lead, write = bridge.leader({ key = "w1", at = 95 }, "w1", 100, 10, 4)
	check.eq(lead and write, true, "own entry past beat: write")
	lead = bridge.leader({ key = 3 }, "", 100, 10, 4)
	check.eq(lead, true, "garbage entry: take it")
end

-- context line
do
	local gw = {
		gateway_state = "running",
		platforms = { telegram = { state = "connected" }, whatsapp = { state = "disconnected" } },
	}
	local devices = {
		{ id = "fa-61d44cb4", name = "LG AC box", session_id = "s1" },
		{ id = "fa-7ae9b284", name = "MHI VRF gateway" },
	}
	local line = bridge.status_line(gw, devices, nil)
	check.truthy(string.find(line, "Hermes gateway running (telegram ok, whatsapp disconnected)", 1, true), "gateway part")
	check.truthy(string.find(line, "ESP devices (2): LG AC box [fa-61d44cb4]; MHI VRF gateway [fa-7ae9b284, no session]", 1, true), "devices part")
	check.truthy(#line <= 400, "within 400 bytes")
	check.truthy(string.find(bridge.status_line(nil, nil, "no flag"), "no state file", 1, true), "missing state")
	check.truthy(string.find(bridge.status_line(gw, nil, "boom"), "ESP devices unknown (boom)", 1, true), "device error")

	local many = {}
	for i = 1, 40 do
		table.insert(many, { id = `fa-{i}`, name = `A very long device name {i}` })
	end
	local long = bridge.status_line(gw, many, nil)
	check.truthy(#long <= 400, "long line clipped")
	check.truthy(utf8.len(long) ~= nil, "clipped on a UTF-8 boundary")
	check.eq(string.sub(long, -3), "…", "clipped line ends in an ellipsis")
end

-- clip on UTF-8 boundaries
do
	check.eq(bridge.clip("abc", 5), "abc", "short kept")
	local s = "éééé" -- 8 bytes
	local c = bridge.clip(s, 6)
	check.truthy(utf8.len(c) ~= nil, "valid utf-8 after clip")
	check.truthy(#c <= 6, "clip bound")
end

-- last_line
do
	check.eq(bridge.last_line("usage: hermes …\n  more\nhermes: error: unrecognized arguments: --list-devices\r\n\n"), "hermes: error: unrecognized arguments: --list-devices", "argparse reason")
	check.eq(bridge.last_line("one"), "one", "single line")
	check.eq(bridge.last_line("hermes: error: no such flag\nRun `hermes --help` to see all commands.\n"), "hermes: error: no such flag", "error line over a trailing hint")
	check.eq(bridge.last_line("  "), "", "blank")
end

-- device parsing and matching
do
	local list = bridge.parse_devices({
		{ id = "fa-61d44cb4", name = "LG AC box", thread_id = 1232, session_id = "s" },
		{ id = "fa-7ae9b284", name = "MHI VRF gateway" },
		{ name = "no id" },
	}) :: { any }
	check.eq(#list, 2, "entries without id dropped")
	check.eq(list[1].thread_id, 1232, "thread id kept")
	check.eq(select(2, bridge.parse_devices("x")), "device list is not a JSON array", "not a list")

	check.eq((bridge.match_device(list, "FA-61D44CB4") :: any).name, "LG AC box", "by id, any case")
	check.eq((bridge.match_device(list, "mhi vrf gateway") :: any).id, "fa-7ae9b284", "by exact name")
	check.eq((bridge.match_device(list, "AC") :: any).id, "fa-61d44cb4", "by name part")
	check.eq(bridge.match_device(list, "a"), nil, "ambiguous part")
	check.eq(bridge.match_device(nil, "x"), nil, "no list")
end

-- device tabs
do
	local tabs = {
		{ id = 10, session = 1, pane = 100, name = "LG AC box", title = "hermes" },
		{ id = 11, session = 2, pane = 101, name = nil, title = "hermes tern --device fa-7ae9b284" },
		{ id = 12, session = 2, pane = 102, name = "lg ac box", title = "x" },
	}
	check.eq((bridge.find_tab(tabs, 2, "fa-61d44cb4", "LG AC box") :: any).id, 12, "by name in session")
	check.eq((bridge.find_tab(tabs, 2, "fa-7ae9b284", "MHI VRF gateway") :: any).id, 11, "by id in title")
	check.eq(bridge.find_tab(tabs, 3, "fa-61d44cb4", "LG AC box"), nil, "other session")
	check.eq(bridge.device_command("fa-61d44cb4"), "hermes tern --device fa-61d44cb4", "plain id")
	check.eq(bridge.device_command('LG "AC"'), 'hermes tern --device "LG AC"', "quoted name")
end

-- export args: optional args left out do not shift cx and the call
do
	local args, cx, call = bridge.split_args("t", "CX", "CALL")
	check.same(args, { "t" }, "one arg")
	check.eq(cx, "CX", "cx")
	check.eq(call, "CALL", "call")
	args, cx = bridge.split_args("t", nil, "a", "CX", "CALL")
	check.eq(args[3], "a", "third arg after a nil")
	check.eq(cx, "CX", "cx after a nil")
	args = bridge.split_args("CX", "CALL")
	check.eq(#args, 0, "no args")
end

-- agents and profiles
do
	local out = bridge.compact_agents({ { pane = 1, cwd = "C:\\", state = "idle", last_message = string.rep("a", 500), extra = 1 } })
	check.eq(#out[1].last_message, 300, "last message clipped")
	check.eq(out[1].extra, nil, "extra fields dropped")
	check.eq(bridge.valid_profile("jira-mentor"), true, "profile name")
	check.eq(bridge.valid_profile("x; rm"), false, "bad profile")
end

return nil
