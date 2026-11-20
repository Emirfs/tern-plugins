--!strict
-- `omp usage --json` samples in the shape of the real output (fields as omp
-- gives them; identifiers are made up). Two profiles see the same Claude account.

local fixture = {}

local H5 = 5 * 3600 * 1000
local D7 = 7 * 24 * 3600 * 1000

local function claude(fetched: number, used5h: number, used7d: number): any
	return {
		provider = "anthropic",
		fetchedAt = fetched,
		metadata = { email = "Ada@Example.com", accountId = "acct-1", orgId = "org-1", orgName = "Example", endpoint = "x" },
		resetCredits = { availableCount = 2, credits = { { status = "available" } } },
		limits = {
			{
				id = "anthropic:five_hour",
				label = "5 hours",
				scope = { provider = "anthropic", windowId = "5h" },
				window = { id = "5h", label = "5 hours", durationMs = H5, resetsAt = 2000000000000 },
				amount = { usedFraction = used5h },
				status = "ok",
			},
			{
				id = "anthropic:seven_day",
				label = "7 days",
				scope = { provider = "anthropic", windowId = "7d" },
				window = { id = "7d", label = "7 days", durationMs = D7, resetsAt = 2000500000000 },
				amount = { used = used7d * 100, limit = 100 },
			},
			{
				id = "anthropic:seven_day_opus",
				label = "7 days Opus",
				scope = { provider = "anthropic", windowId = "7d", tier = " Opus " },
				window = { id = "7d", label = "7 days", durationMs = D7, resetsAt = 2000500000000 },
				amount = { remainingFraction = 0.9 },
			},
		},
	}
end

local function codex(): any
	return {
		provider = "openai-codex",
		fetchedAt = 100,
		metadata = { email = "bob@example.com", accountId = "acct-2", planType = "plus", meterStates = {} },
		limits = {
			{
				id = "openai-codex:primary",
				label = "5 hours",
				scope = { provider = "openai-codex", windowId = "5h", shared = true },
				window = { id = "5h", label = "5 hours", durationMs = H5, resetsAt = 2000000000000 },
				amount = { used = 13, limit = 100 },
			},
			{
				-- A limit with unknown usage: no fields at all.
				id = "openai-codex:secondary",
				label = "7 days",
				scope = { provider = "openai-codex", windowId = "7d" },
				window = { id = "7d", label = "7 days", durationMs = D7 },
				amount = {},
			},
			{
				id = "openai-codex:spark:primary",
				label = "Spark 5 hours",
				scope = { provider = "openai-codex", windowId = "5h" },
				window = { id = "5h", label = "5 hours", durationMs = H5 },
				amount = { usedFraction = 0.5 },
			},
		},
	}
end

local function antigravity(): any
	local function shared(id: string, used: number): any
		return {
			id = id,
			label = "Claude & GPT",
			scope = { sharedGroup = "claude-gpt" },
			window = { durationMs = H5 },
			amount = { usedFraction = used },
		}
	end
	return {
		provider = "google-antigravity",
		fetchedAt = 100,
		metadata = { projectId = "proj-9" },
		limits = { shared("ag:claude", 0.25), shared("ag:gpt", 0.25) },
	}
end

--- `default` profili: eski (fetchedAt 100) Claude raporu, Codex, Antigravity, sorunlar.
function fixture.default(): any
	return {
		generatedAt = 1,
		capacity = { ignored = true },
		reports = { claude(100, 0.1, 0.2), codex(), antigravity() },
		accountsWithoutUsage = { { provider = "github-copilot", email = "ada@example.com", token = "secret" } },
		disabledCredentials = {
			{ provider = "anthropic", email = "old@example.com", cause = "token expired\nstack trace", refreshToken = "secret" },
		},
	}
end

--- The `work` profile: the same Claude account (differing in letter case), fresher; the same problem account.
function fixture.work(): any
	local fresh = claude(200, 0.6, 0.7)
	fresh.metadata.email = "ada@example.com"
	return {
		reports = { fresh },
		accountsWithoutUsage = { { provider = "github-copilot", email = "ada@example.com" } },
		disabledCredentials = {},
	}
end

return fixture
