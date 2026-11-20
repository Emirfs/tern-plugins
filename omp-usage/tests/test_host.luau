--!strict
-- Block end to end: host.luau under a stub runtime; the test supplies the process results.
local check = require("./check")
local fixture = require("./fixture")
local stub = require("./host_stub")
local usage = require("../lib/usage")

local ROOT = "omp-usage"

local function key(name: string): any
	return { name = name, text = name, ctrl = false, alt = false, meta = false, shift = false }
end

local function view_text(h: stub.Harness, state: any): string
	return stub.text(h.blocks.accounts.view(state, h.cx).main)
end

-- The cache draws before the first fetch; a failing profile keeps its old data
do
	local h = stub.host(ROOT, { "work" })
	h.kv.cache = {
		v = 1,
		fetched = 1000,
		order = { "default", "work" },
		profiles = {
			default = { data = usage.trim(fixture.default()), at = 1000 },
			work = { data = usage.trim(fixture.work()), at = 1000 },
		},
	}
	local state = h.blocks.accounts.init(h.cx, {}, nil)
	check.eq(#h.procs, 2, "one omp run per profile")
	local first = view_text(h, state)
	check.truthy(string.find(first, "Claude", 1, true), "cached accounts are drawn before omp answers")
	check.truthy(string.find(first, "(cached)", 1, true), "cached data is marked")
	check.eq(h.blocks.accounts.title(state), "omp usage · 3 accounts", "title counts cached accounts once across profiles")

	local default_proc, work_proc = h.procs[1], h.procs[2]
	check.eq(default_proc.env.OMP_PROFILE, "default", "default profile env")
	check.same(work_proc.argv, { "omp", "--profile", "work", "usage", "--json" }, "named profile argv")

	h.finish(default_proc, { data = fixture.default() })
	h.finish(work_proc, { status = 1, stderr = "boom\nmore" })
	check.eq(h.renders, 1, "renders once when every profile settled")

	local after = view_text(h, state)
	check.eq(string.find(after, "(cached)", 1, true), nil, "fresh fetch clears the cache mark")
	check.truthy(string.find(after, "work: omp exited with 1: boom", 1, true), "failure is reported with its first stderr line")
	check.truthy(string.find(after, "showing data from", 1, true), "failed profile says it shows older data")
	check.eq(h.blocks.accounts.title(state), "omp usage · 3 accounts", "failed profile keeps its last accounts")

	local cache = h.kv.cache
	check.eq(cache.v, 1, "cache rewritten")
	check.truthy(cache.profiles.work ~= nil, "cache keeps the failed profile's last good data")
	check.eq(cache.profiles.default.data.capacity, nil, "cache holds the trimmed output")
end

-- A corrupt cache is ignored
do
	local h = stub.host(ROOT, {})
	h.kv.cache = { v = 99, profiles = "junk" }
	local state = h.blocks.accounts.init(h.cx, {}, nil)
	check.truthy(string.find(view_text(h, state), "Reading usage", 1, true), "unknown cache version shows the loading state")
end

-- omp candidates on Windows: the name on PATH, then Windows paths only
do
	local bun = "C:\\home\\.bun\\bin\\omp.exe"
	local h = stub.host(ROOT, {}, { bun })
	h.missing.omp = true
	h.blocks.accounts.init(h.cx, {}, nil)
	check.eq(#h.procs, 1, "falls back when omp is not on PATH")
	check.eq(h.procs[1].argv[1], bun, "uses the bun install")
	for _, path in h.probed do
		check.eq(string.find(path, "/opt/", 1, true), nil, "no unix path probed on Windows: " .. path)
	end
end

-- If omp is missing at all, the reason is shown
do
	local h = stub.host(ROOT, {})
	h.missing.omp = true
	local state = h.blocks.accounts.init(h.cx, {}, nil)
	check.truthy(string.find(view_text(h, state), "default: omp failed to start", 1, true), "spawn failure is reported")
end

-- Only r and R are keys; l (the old language switch) and ctrl combinations are not handled
do
	local h = stub.host(ROOT, {})
	local state = h.blocks.accounts.init(h.cx, {}, nil)
	check.eq(h.blocks.accounts.key(state, key("r"), h.cx), true, "r is handled")
	check.eq(h.blocks.accounts.key(state, key("R"), h.cx), true, "R is handled")
	check.eq(h.blocks.accounts.key(state, key("l"), h.cx), false, "l is not handled")
	check.eq(h.blocks.accounts.key(state, { name = "r", ctrl = true }, h.cx), false, "ctrl+r is not ours")
end
