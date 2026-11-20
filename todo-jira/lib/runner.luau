--!strict
-- Runs backend.py the same way for both halves: environment from the config file, same argv, same reply decoding.
local Runner = {}

Runner.TIMEOUT_MS = 60000

function Runner.env(): { [string]: string }
	local env: { [string]: string } = { PYTHONIOENCODING = "utf-8" }
	local path = tern.plugin.data .. "/config.json"
	if tern.fs.exists(path) then
		local raw = tern.json.decode(tern.fs.read(path, 4096))
		if type(raw) == "table" then
			if type(raw.jira_url) == "string" then
				env.TERN_JIRA_URL = raw.jira_url
			end
			if type(raw.vault) == "string" then
				env.TERN_HAFIZA_DIR = raw.vault
			end
		end
	end
	return env
end

function Runner.argv(): { string }
	return { tern.getenv("TERN_TODO_PYTHON") or "python", "-B", "backend.py" }
end

-- Process result → (data, error). The error text is shown to the user.
function Runner.decode(result: ProcessResult): (any, string?)
	if result.status ~= 0 then
		return nil, "The local Todo operation did not complete. If it was a write, check the target before repeating it."
	end
	local ok, reply = pcall(tern.json.decode, result.stdout)
	if not ok or type(reply) ~= "table" then
		return nil, "The local Todo operation did not return a JSON reply."
	end
	return reply.data, reply.error
end

return Runner
