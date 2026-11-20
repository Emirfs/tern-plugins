--!strict
local check = require("./check")
local fixture = require("./fixture")
local L = require("../lib/text")
local usage = require("../lib/usage")

local H5 = 5 * 3600 * 1000
local D7 = 7 * 24 * 3600 * 1000

local function runs(default: any, work: any): any
	return { default = { data = default }, work = { data = work } }
end

local function find(providers: { usage.Provider }, id: string): usage.Provider?
	for _, p in providers do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- Aggregation: the same account in two profiles once, with the freshest report
do
	local providers, issues = usage.aggregate({ "default", "work" }, runs(fixture.default(), fixture.work()))
	local ids = {}
	for _, p in providers do
		table.insert(ids, p.id)
	end
	check.same(ids, { "anthropic", "openai-codex", "google-antigravity" }, "provider order")

	local claude = find(providers, "anthropic") :: usage.Provider
	check.eq(#claude.accounts, 1, "same e-mail (any case) and org across profiles is one account")
	local acc = claude.accounts[1]
	check.same(acc.profiles, { "default", "work" }, "account lists both profiles")
	check.eq(acc.fetched, 200, "freshest report wins")
	check.eq(acc.windows["d:" .. H5].used, 0.6, "5h window from the fresher report")
	check.eq(acc.windows["d:" .. D7].used, 0.7, "used/limit converts to a fraction")
	check.truthy(math.abs(acc.windows["d:" .. D7 .. "|m:opus"].used - 0.1) < 1e-9, "tier limit keeps its own pool")
	check.eq(acc.resets, 2, "reset credits")

	local codex = find(providers, "openai-codex") :: usage.Provider
	local cw = codex.accounts[1].windows
	check.eq(cw["d:" .. H5].used, 0.13, "codex primary is the chat pool")
	check.eq(cw["d:" .. D7], nil, "a limit with no usage fields is not reported as 0% used")
	check.eq(cw["d:" .. H5 .. "|m:spark"].used, 0.5, "spark gets its own pool")

	local ag = find(providers, "google-antigravity") :: usage.Provider
	check.eq(#ag.accounts[1].limits, 1, "shared group reported twice counts once")
	check.eq(ag.accounts[1].label, "proj-9", "project id labels an account without e-mail")

	check.eq(#issues, 2, "issues deduplicated across profiles")
	check.eq(issues[1].kind, "no_report", "no-report issue")
	check.same(issues[1].profiles, { "default", "work" }, "issue lists both profiles")
	check.eq(issues[2].kind, "disabled", "disabled issue")
	check.eq(issues[2].detail, "token expired", "disabled cause keeps its first line")

	local cols = usage.columns_of(providers, L)
	local labels = {}
	for _, c in cols do
		table.insert(labels, c.label)
	end
	check.same(labels, { "5 hours", "5 hours spark", "7 days", "7 days opus" }, "columns short to long, pools after the main one")
end

-- A different org with the same e-mail is a separate account
do
	local other = fixture.work()
	other.reports[1].metadata.orgId = "org-2"
	local providers = usage.aggregate({ "default", "work" }, runs(fixture.default(), other))
	check.eq(#(find(providers, "anthropic") :: usage.Provider).accounts, 2, "different org is a different account")
end

-- Without profile data (an error) aggregation skips it
do
	local providers = usage.aggregate({ "default", "work" }, { default = { data = nil }, work = { data = fixture.work() } })
	check.eq(#providers, 1, "profile without data is skipped")
end

-- used_fraction
do
	check.eq(usage.used_fraction(nil), nil, "no amount")
	check.eq(usage.used_fraction({}), nil, "empty amount is unknown, not 0")
	check.eq(usage.used_fraction({ used = 5, limit = 0 }), nil, "zero limit is unknown")
	check.eq(usage.used_fraction({ usedFraction = 1.4 }), 1, "clamped to 1")
	check.eq(usage.used_fraction({ remainingFraction = 0.25 }), 0.75, "from remaining")
	check.eq(usage.used_fraction({ usedFraction = 0 / 0 }), nil, "NaN is unknown")
end

-- trim: the copy sent to the cache does not change the aggregate and carries nothing extra
do
	local raw_d, raw_w = fixture.default(), fixture.work()
	local a = usage.aggregate({ "default", "work" }, runs(raw_d, raw_w))
	local b = usage.aggregate({ "default", "work" }, runs(usage.trim(raw_d), usage.trim(raw_w)))
	check.same(b, a, "aggregate over trimmed data equals aggregate over raw data")

	local function has_secret(v: any): boolean
		if v == "secret" then
			return true
		end
		if type(v) == "table" then
			for _, x in v do
				if has_secret(x) then
					return true
				end
			end
		end
		return false
	end
	check.eq(has_secret(usage.trim(raw_d)), false, "tokens and unknown fields are dropped")
	check.eq(usage.trim({ nope = true }), nil, "output without reports is rejected")
end
