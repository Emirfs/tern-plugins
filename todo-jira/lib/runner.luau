--!strict
-- backend.py'yi iki yarı da aynı biçimde çalıştırır: ayar dosyasından gelen ortam, aynı argv, aynı yanıt çözümü.
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

-- Sürecin sonucu → (veri, hata). Hata metni kullanıcıya gösterilir.
function Runner.decode(result: ProcessResult): (any, string?)
	if result.status ~= 0 then
		return nil, "Yerel Todo işlemi tamamlanamadı. Yazma işlemi ise tekrar etmeden önce hedefi kontrol edin."
	end
	local ok, reply = pcall(tern.json.decode, result.stdout)
	if not ok or type(reply) ~= "table" then
		return nil, "Yerel Todo işlemi JSON yanıtı vermedi."
	end
	return reply.data, reply.error
end

return Runner
