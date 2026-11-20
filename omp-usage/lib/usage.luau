--!strict
-- Turns `omp usage --json` reports into accounts and aggregates them across
-- profiles. Pure: does not touch Tern and produces no text (issues come back as
-- codes), so it is testable. The rules follow omp's own `capacity` computation.

local fmt = require("./fmt")

local usage = {}

usage.PROVIDER_ORDER = { "anthropic", "openai-codex", "google-antigravity" }

export type Limit = {
	key: string,
	label: string,
	used: number?,
	resets: number?,
	duration: number?,
	meter: string?,
	status: string?,
}

-- The binding (most used) limit of one account in one window.
export type Cell = { used: number, resets: number?, status: string? }

export type Account = {
	provider: string,
	key: string,
	-- E-mail, account or project id; nil if there is none (the view writes "unknown account").
	label: string?,
	org: string?,
	profiles: { string },
	fetched: number,
	limits: { Limit },
	resets: number,
	windows: { [string]: Cell },
}

-- One window column of the table: the duration (5 hours, 7 days) and, if any, a separate quota pool.
export type Column = { key: string, label: string, duration: number?, meter: string? }

export type Provider = { id: string, accounts: { Account } }

export type IssueKind = "no_report" | "disabled"

export type Issue = { provider: string, who: string, kind: IssueKind, detail: string?, profiles: { string } }

-- Profile name → last successful `omp usage --json` output (nil if none).
export type Runs = { [string]: { data: any? } }

--- Counterpart of omp's `resolveUsedFraction`: the used fraction, 0–1. nil if no
--- field is present: unknown usage is never counted as 0.
function usage.used_fraction(amount: any): number?
	if type(amount) ~= "table" then
		return nil
	end
	local f: number? = nil
	if type(amount.usedFraction) == "number" then
		f = amount.usedFraction
	elseif type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0 then
		f = amount.used / amount.limit
	elseif type(amount.remainingFraction) == "number" then
		f = 1 - amount.remainingFraction
	end
	if f == nil or f ~= f then
		return nil
	end
	return math.clamp(f, 0, 1)
end

--- Counterpart of omp's `meterForLimit`: limits that keep a separate quota pool in the same window.
function usage.meter_of(provider: string, limit: any): string?
	if provider ~= "anthropic" and provider ~= "openai-codex" then
		return nil
	end
	local scope = if type(limit.scope) == "table" then limit.scope else {}
	local tier = if type(scope.tier) == "string" then string.lower(string.match(scope.tier, "^%s*(.-)%s*$") or "") else ""
	if tier ~= "" then
		return tier
	end
	if provider ~= "openai-codex" then
		return nil
	end
	local slug = string.match(string.lower(tostring(limit.id or "")), "^[^:]*:([^:]+)")
	if slug and slug ~= "primary" and slug ~= "secondary" then
		return slug
	end
	return "chat"
end

local function limit_label(limit: any): string
	local label = tostring(limit.label or limit.id or "?")
	local win = if type(limit.window) == "table" then limit.window.label else nil
	if type(win) == "string" and not string.find(string.lower(label), string.lower(win), 1, true) then
		return label .. " (" .. win .. ")"
	end
	return label
end

--- An account's identity across profiles: provider + e-mail (+ org), else the account id.
function usage.identity(provider: string, md: any): string?
	if type(md) ~= "table" then
		return nil
	end
	if type(md.email) == "string" then
		return provider .. "|email:" .. string.lower(md.email) .. (if type(md.orgId) == "string" then "|org:" .. md.orgId else "")
	end
	if type(md.accountId) == "string" then
		return provider .. "|acct:" .. md.accountId
	end
	return nil
end

local function org_text(md: any): string?
	if type(md) ~= "table" or type(md.orgName) ~= "string" then
		return nil
	end
	if type(md.email) == "string" and md.orgName == md.email .. "'s Organization" then
		return nil
	end
	return md.orgName
end

local function add_unique(list: { string }, value: string)
	if not table.find(list, value) then
		table.insert(list, value)
	end
end

local function account_of(provider: string, report: any, profile: string, index: number): Account
	local md = report.metadata
	local key = usage.identity(provider, md) or (provider .. "|" .. profile .. "#" .. index)
	local label = if type(md) == "table" then (md.email or md.accountId or md.projectId) else nil
	local limits: { Limit } = {}
	local seen: { [string]: boolean } = {}
	for _, limit in (if type(report.limits) == "table" then report.limits else {}) do
		local scope = if type(limit.scope) == "table" then limit.scope else {}
		local window = if type(limit.window) == "table" then limit.window else {}
		-- Antigravity reports the same shared quota (Claude & GPT) twice.
		local lkey = if type(scope.sharedGroup) == "string" then "g:" .. scope.sharedGroup else "i:" .. tostring(limit.id)
		if not seen[lkey] then
			seen[lkey] = true
			table.insert(limits, {
				key = lkey,
				label = limit_label(limit),
				used = usage.used_fraction(limit.amount),
				resets = if type(window.resetsAt) == "number" then window.resetsAt else nil,
				duration = if type(window.durationMs) == "number" then window.durationMs else nil,
				meter = usage.meter_of(provider, limit),
				status = if type(limit.status) == "string" then limit.status else nil,
			})
		end
	end
	table.sort(limits, function(a, b)
		local da, db = a.duration or math.huge, b.duration or math.huge
		if da ~= db then
			return da < db
		end
		return a.label < b.label
	end)
	local credits = if type(report.resetCredits) == "table" then report.resetCredits.availableCount else nil
	return {
		provider = provider,
		key = key,
		label = if label ~= nil then tostring(label) else nil,
		org = org_text(md),
		profiles = { profile },
		fetched = if type(report.fetchedAt) == "number" then report.fetchedAt else 0,
		limits = limits,
		resets = if type(credits) == "number" then credits else 0,
		windows = {},
	}
end

-- The window key goes by duration; separate pools other than Codex's default "chat"
-- pool (model-scoped tier, Spark) get their own column.
local function window_key(l: Limit): string
	local wkey = if l.duration then "d:" .. l.duration else "l:" .. l.label
	local meter = if l.meter == "chat" then nil else l.meter
	return if meter then wkey .. "|m:" .. meter else wkey
end

--- The logic of omp's `computeProviderWindowStats`: per window, the account's most
--- used limit binds the account in that window. A limit with unknown usage is skipped.
function usage.windows_of(acc: Account): { [string]: Cell }
	local out: { [string]: Cell } = {}
	for _, l in acc.limits do
		local used = l.used
		if used ~= nil then
			local key = window_key(l)
			local c = out[key]
			if c == nil or used > c.used then
				out[key] = { used = used, resets = l.resets, status = l.status }
			end
		end
	end
	return out
end

--- The window columns of all accounts, short to long; names come from the `L` text table.
function usage.columns_of(providers: { Provider }, L: { [string]: string }): { Column }
	local seen: { [string]: boolean } = {}
	local list: { Column } = {}
	for _, prov in providers do
		for _, acc in prov.accounts do
			for _, l in acc.limits do
				local key = window_key(l)
				if l.used ~= nil and not seen[key] then
					seen[key] = true
					local meter = if l.meter == "chat" then nil else l.meter
					local label = if l.duration then fmt.window_name(l.duration, L) else l.label
					table.insert(list, {
						key = key,
						label = if meter then label .. " " .. meter else label,
						duration = l.duration,
						meter = meter,
					})
				end
			end
		end
	end
	table.sort(list, function(a, b)
		local da, db = a.duration or math.huge, b.duration or math.huge
		if da ~= db then
			return da < db
		end
		return (a.meter or "") < (b.meter or "")
	end)
	return list
end

--- Aggregates the reports of the profiles in `order` into accounts. The same account
--- (see `identity`) is counted once; its freshest report wins.
function usage.aggregate(order: { string }, runs: Runs): ({ Provider }, { Issue })
	local by_key: { [string]: Account } = {}
	local by_provider: { [string]: { Account } } = {}
	local issues: { [string]: Issue } = {}
	local issue_list: { Issue } = {}

	local function issue(provider: string, entry: any, kind: IssueKind, detail: string?, profile: string)
		local who = tostring(entry.email or entry.accountId or entry.orgName or "?")
		local key = provider .. "|" .. who .. "|" .. kind .. "|" .. (detail or "")
		local found = issues[key]
		if found then
			add_unique(found.profiles, profile)
			return
		end
		local item: Issue = { provider = provider, who = who, kind = kind, detail = detail, profiles = { profile } }
		issues[key] = item
		table.insert(issue_list, item)
	end

	for _, name in order do
		local data = runs[name] and runs[name].data
		if type(data) == "table" then
			for i, report in (if type(data.reports) == "table" then data.reports else {}) do
				local provider = tostring(report.provider or "?")
				local acc = account_of(provider, report, name, i)
				local prev = by_key[acc.key]
				if prev then
					add_unique(prev.profiles, name)
					if acc.fetched > prev.fetched then
						prev.fetched, prev.limits, prev.resets = acc.fetched, acc.limits, acc.resets
						prev.org = acc.org or prev.org
					end
				else
					by_key[acc.key] = acc
					by_provider[provider] = by_provider[provider] or {}
					table.insert(by_provider[provider], acc)
				end
			end
			for _, entry in (if type(data.accountsWithoutUsage) == "table" then data.accountsWithoutUsage else {}) do
				issue(tostring(entry.provider or "?"), entry, "no_report", nil, name)
			end
			for _, entry in (if type(data.disabledCredentials) == "table" then data.disabledCredentials else {}) do
				issue(tostring(entry.provider or "?"), entry, "disabled", fmt.first_line(tostring(entry.cause or "")), name)
			end
		end
	end

	local ids: { string } = {}
	for id in by_provider do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ia, ib = table.find(usage.PROVIDER_ORDER, a) or 99, table.find(usage.PROVIDER_ORDER, b) or 99
		if ia ~= ib then
			return ia < ib
		end
		return a < b
	end)

	local providers: { Provider } = {}
	for _, id in ids do
		local accounts = by_provider[id]
		table.sort(accounts, function(a, b)
			return (a.label or "") < (b.label or "")
		end)
		for _, acc in accounts do
			table.sort(acc.profiles)
			acc.windows = usage.windows_of(acc)
		end
		table.insert(providers, { id = id, accounts = accounts })
	end
	return providers, issue_list
end

local function pick(src: any, fields: { string }): { [string]: any }?
	if type(src) ~= "table" then
		return nil
	end
	local out: { [string]: any } = {}
	for _, f in fields do
		local v = src[f]
		if type(v) == "string" or type(v) == "number" then
			out[f] = v
		end
	end
	return out
end

local function each_picked(list: any, fields: { string }, extra: ((any, { [string]: any }) -> ())?): { any }
	local out: { any } = {}
	for _, item in (if type(list) == "table" then list else {}) do
		local p = pick(item, fields)
		if p then
			if extra then
				extra(item, p)
			end
			table.insert(out, p)
		end
	end
	return out
end

local WHO = { "provider", "email", "accountId", "orgName" }

--- Only the fields of the `omp usage --json` output that this plugin reads: so the cache
--- (`tern.kv`) stays small and no needless credentials are written to disk.
function usage.trim(data: any): any
	if type(data) ~= "table" or type(data.reports) ~= "table" then
		return nil
	end
	local reports = each_picked(data.reports, { "provider", "fetchedAt" }, function(report, out)
		out.metadata = pick(report.metadata, { "email", "accountId", "projectId", "orgId", "orgName" })
		local credits = if type(report.resetCredits) == "table" then report.resetCredits.availableCount else nil
		if type(credits) == "number" then
			out.resetCredits = { availableCount = credits }
		end
		out.limits = each_picked(report.limits, { "id", "label", "status" }, function(limit, l)
			l.scope = pick(limit.scope, { "tier", "sharedGroup" })
			l.window = pick(limit.window, { "label", "resetsAt", "durationMs" })
			l.amount = pick(limit.amount, { "usedFraction", "used", "limit", "remainingFraction" })
		end)
	end)
	return {
		reports = reports,
		accountsWithoutUsage = each_picked(data.accountsWithoutUsage, WHO),
		disabledCredentials = each_picked(data.disabledCredentials, WHO, function(entry, out)
			out.cause = fmt.first_line(tostring(entry.cause or ""))
		end),
	}
end

return usage
