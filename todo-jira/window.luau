--!strict
local sync = require("./sync")
type Issue = sync.Issue
type Card = sync.Card
type Change = sync.Change
type Draft = {key: string, id: string, text: string, digest: string}

local home = tern.getenv("USERPROFILE") or tern.getenv("HOME") or ""
local boardPath = tern.getenv("TERN_TODO_PATH") or (home .. "/TODO.md")
local refreshMs = 5 * 60 * 1000
local issues: {Issue} = {}
local drafts: {Draft} = {}
local busy = false
local alerted = ""

local function localConfig(): {[string]: string}
	local path = tern.plugin.data .. "/config.json"
	if not tern.fs.exists(path) then
		return {}
	end
	local raw = tern.json.decode(tern.fs.read(path, 4096))
	return { TERN_JIRA_URL = raw.jira_url, TERN_TODO_MEMORY_INDEX = raw.memory_index }
end

local function backend(cx: WindowCx, data: any, cb: (WindowCx, any, string?) -> ())
	local ok, err = pcall(function()
		local env = localConfig()
		env.PYTHONIOENCODING = "utf-8"
		tern.process.run({tern.getenv("TERN_TODO_PYTHON") or "python", "-B", "backend.py"}, {
			cwd = tern.plugin.dir, timeout_ms = 60000, stdin = tern.json.encode(data), env = env,
		}, function(result: ProcessResult, fresh: WindowCx?)
			if not fresh then return end
			if result.status ~= 0 then
				cb(fresh, nil, "Yerel Todo işlemi tamamlanamadı. Yazma işlemi ise tekrar etmeden önce hedefi kontrol edin.")
				return
			end
			local decoded, reply = pcall(tern.json.decode, result.stdout)
			if not decoded or type(reply) ~= "table" then
				cb(fresh, nil, "Yerel Todo işlemi JSON yanıtı vermedi.")
				return
			end
			cb(fresh, reply.data, reply.error)
		end)
	end)
	if not ok then
		cb(cx, nil, `Todo bağlantısı başlatılamadı: {err}`)
	end
end

local function readBoard(cx: WindowCx, cb: (WindowCx, {Card}?, {[string]: string}?, string?) -> ())
	cx.board:read(boardPath, {rows = 500, max_chars = 4096}):next(function(snapshot, err, fresh)
		if not fresh then return end
		if not snapshot or snapshot.phase ~= "ready" then
			cb(fresh, nil, nil, err or "TODO panosu henüz hazır değil.")
		elseif snapshot.more > 0 or snapshot.open + snapshot.done > 500 then
			cb(fresh, nil, nil, "TODO panosu 500 kartı geçti. Eksik veriyle eşitleme yapılmadı.")
		else
			local cards, lanes = sync.cards(snapshot)
			cb(fresh, cards, lanes, nil)
		end
	end)
end

local function storeBase(value: {[string]: Issue})
	tern.kv.set("jira-baseline", value)
end

local function applyBoard(cx: WindowCx, lanes: {[string]: string}, edits: {sync.LocalEdit}, done: (WindowCx, string?) -> ())
	local i = 0
	local step: (WindowCx) -> ()
	local function nextEdit(fresh: WindowCx, edit: sync.LocalEdit)
		local title = if edit.title then sync.title(edit.issue.key, edit.title) else nil
		local due = if edit.due == "" then false else edit.due
		local function complete(result: any, err: string?, current: WindowCx?)
			if not current then return end
			if err or not result then done(current, err or "Pano değişikliği kaydedilemedi."); return end
			step(current)
		end
		if edit.card then
			local card = edit.card
			local function move(current: WindowCx)
				if edit.lane and lanes[edit.lane] then
					current.board:move(card.id, lanes[edit.lane]):next(complete)
				else
					step(current)
				end
			end
			if title or due ~= nil then
				fresh.board:edit(card.id, {text = title, due = due}):next(function(result, err, current)
					if not current then return end
					if err or not result then done(current, err or "Kart düzenlenemedi.") else move(current) end
				end)
			else
				move(fresh)
			end
		else
			local lane = assert(edit.lane)
			fresh.board:add(boardPath, {lane = lanes[lane], text = assert(title), due = due}):next(complete)
		end
	end
	step = function(fresh)
		i += 1
		local edit = edits[i]
		if not edit then done(fresh, nil); return end
		local lane = edit.lane
		if lane and lanes[lane] == "" then
			done(fresh, `Birden fazla “{lane}” sütunu var; eşitleme durdu.`)
		elseif lane and not lanes[lane] then
			fresh.board:add_lane(boardPath, {title = lane}):next(function(id, err, current)
				if not current then return end
				if not id then done(current, err or "Sütun açılamadı."); return end
				lanes[lane] = id
				nextEdit(current, edit)
			end)
		else
			nextEdit(fresh, edit)
		end
	end
	step(cx)
end

local function scanMemory(cx: WindowCx, notify: boolean, done: (WindowCx, string?) -> ())
	backend(cx, {op = "memory", issues = tern.json.array(issues), seen = tern.kv.get("memory-applied") or {}}, function(fresh, data, err)
		if not err then
			drafts = data
			local ids = {}
			for _, draft in drafts do table.insert(ids, draft.key .. draft.digest) end
			table.sort(ids)
			local current = table.concat(ids, ":")
			if notify and current ~= "" and current ~= alerted then
				fresh:toast("info", `Todo · Jira: {#drafts} önemli hafıza değişikliği`, "Değişiklikler → Doldur; Jira’ya henüz yazılmadı.")
			end
			alerted = current
			tern.chrome.refresh()
		end
		done(fresh, err)
	end)
end

local function refresh(cx: WindowCx, quiet: boolean, done: ((WindowCx, {Change}, {string}) -> ())?)
	if busy then
		if not quiet then cx:toast("info", "Todo · Jira eşitlemesi sürüyor.") end
		return
	end
	busy = true
	local function fail(fresh: WindowCx, err: string)
		busy = false
		if not quiet then fresh:toast("error", "Todo · Jira yenilenemedi", err) end
	end
	backend(cx, {op = "assigned"}, function(fresh, assigned, err)
		if err then fail(fresh, err); return end
		readBoard(fresh, function(now, cards, lanes, boardErr)
			if not cards or not lanes then fail(now, boardErr or "TODO panosu okunamadı."); return end
			local edits, changes, conflicts, baseline = sync.plan(assigned, cards, tern.kv.get("jira-baseline") or {})
			applyBoard(now, lanes, edits, function(current, writeErr)
				if writeErr then fail(current, writeErr); return end
				storeBase(baseline)
				issues = assigned
				scanMemory(current, quiet, function(last, memoryErr)
					busy = false
					if memoryErr and not quiet then last:toast("error", "Hafıza önizlemesi yenilenemedi", memoryErr) end
					if done then
						done(last, changes, conflicts)
					elseif not quiet then
						last:toast("success", `{#assigned} Jira kartı · {#edits} pano güncellemesi`, `{#changes} gönderilebilir düzenleme · {#conflicts} çakışma`)
					end
				end)
			end)
		end)
	end)
end

local function pick(cx: WindowCx, title: string, rows: {PickItem}, cb: (WindowCx, PickItem) -> ())
	cx:pick({placeholder = title, items = rows}):next(function(row, err, fresh)
		if row and not err and fresh then cb(fresh, row) end
	end)
end

local function approve(cx: WindowCx, title: string, action: string, details: {PickItem}, cb: (WindowCx) -> ())
	table.insert(details, {label = action, approve = true})
	pick(cx, title, details, function(fresh, row)
		if row.approve then cb(fresh) end
	end)
end

local function jiraWrite(cx: WindowCx, data: any, cb: (WindowCx, any) -> ())
	if busy then cx:toast("info", "Todo · Jira eşitlemesi sürüyor."); return end
	busy = true
	backend(cx, data, function(fresh, reply, err)
		busy = false
		if err then fresh:toast("error", "Jira’ya gönderilemedi", err) else cb(fresh, reply) end
	end)
end

local function sendChange(cx: WindowCx, change: Change, value: string, name: string)
	local issue = change.issue
	local old = if change.field == "status" then issue.status_name else change.before
	approve(cx, issue.key .. " · Jira’ya gönder", "Jira’ya gönder", {
		{label = "Önce: " .. (old ~= "" and old or "—")},
		{label = "Sonra: " .. (name ~= "" and name or "—")},
	}, function(fresh)
		readBoard(fresh, function(current, cards, _, err)
			if not cards then current:toast("error", "TODO okunamadı", err); return end
			local _, pending = sync.plan(issues, cards, tern.kv.get("jira-baseline") or {})
			for _, candidate in pending do
				if candidate.issue.id == issue.id and candidate.field == change.field and candidate.before == change.before
					and candidate.value == change.value and candidate.card.id == change.card.id then
					jiraWrite(current, {op = "change", key = issue.key, id = issue.id, field = change.field,
						before = change.before, value = value, lane = change.value}, function(last, _)
						last:toast("success", issue.key .. " Jira’da güncellendi.")
						refresh(last, true, nil)
					end)
					return
				end
			end
			current:toast("error", "Düzenleme değişti; yeniden önizleyin.")
		end)
	end)
end

local function showChange(cx: WindowCx, change: Change)
	if change.field ~= "status" then sendChange(cx, change, change.value, change.value); return end
	local issue = change.issue
	backend(cx, {op = "transitions", key = issue.key, id = issue.id, before = change.before, lane = change.value}, function(fresh, data, err)
		if err then fresh:toast("error", "Jira durumları alınamadı", err); return end
		local rows: {PickItem} = {}
		for _, t in data do table.insert(rows, {label = t.name, detail = t.action, id = t.id}) end
		if #rows == 0 then fresh:toast("info", issue.key .. " için bu sütuna Jira geçişi yok."); return end
		pick(fresh, issue.key .. " · Jira durumu", rows, function(current, row)
			sendChange(current, change, row.id, row.label)
		end)
	end)
end

local function showDraft(cx: WindowCx, draft: Draft)
	local details: {PickItem} = {}
	local line = ""
	for word in string.gmatch(draft.text, "%S+") do
		if #line + #word > 80 and line ~= "" then
			table.insert(details, {label = line})
			line = ""
		end
		line ..= (if line == "" then "" else " ") .. word
	end
	if line ~= "" then table.insert(details, {label = line}) end
	approve(cx, draft.key .. " · Özel önizleme · Jira ilerleme yorumu", "Doldur · Bu metni Jira’ya gönder", details, function(fresh)
		for _, current in drafts do
			if current.id == draft.id and current.digest == draft.digest then
				jiraWrite(fresh, {op = "comment", key = draft.key, id = draft.id, text = draft.text}, function(last, _)
					local seen = tern.kv.get("memory-applied") or {}
					seen[draft.key] = draft.digest
					tern.kv.set("memory-applied", seen)
					for i, item in drafts do if item == current then table.remove(drafts, i); break end end
					tern.chrome.refresh()
					last:toast("success", draft.key .. " ilerleme yorumu Jira’da doğrulandı.")
				end)
				return
			end
		end
		fresh:toast("info", "Bu önizleme değişti; yeniden açın.")
	end)
end

local function preview(cx: WindowCx, memoryOnly: boolean)
	refresh(cx, false, function(fresh, changes, conflicts)
		local rows: {PickItem} = {}
		for _, draft in drafts do
			table.insert(rows, {label = draft.key, detail = draft.text, group = "Hafıza · özel önizlemeler", draft = draft})
		end
		if not memoryOnly then
			for _, change in changes do
				local label = if change.field == "title" then "Başlık" elseif change.field == "due" then "Termin" else "Durum"
				table.insert(rows, {label = change.issue.key .. " · " .. label, detail = change.value, group = "Jira’ya gönderilebilir", change = change})
			end
			for _, conflict in conflicts do table.insert(rows, {label = conflict, group = "Çakışmalar · hiçbir şey yazılmadı"}) end
		end
		if #rows == 0 then fresh:toast("info", "Gönderilecek önemli değişiklik yok."); return end
		pick(fresh, "Todo · Jira · Değişiklikler", rows, function(current, row)
			if row.draft then showDraft(current, row.draft) elseif row.change then showChange(current, row.change) end
		end)
	end)
end

local function kanban(cx: WindowCx)
	readBoard(cx, function(fresh, cards, _, err)
		if not cards then fresh:toast("error", "TODO okunamadı", err); return end
		local rows: {PickItem} = {}
		for _, card in cards do table.insert(rows, {label = card.text, detail = card.lane, card = card}) end
		if #rows == 0 then fresh:toast("info", "Atanacak TODO kartı yok."); return end
		pick(fresh, "Hermes Kanban’a gönderilecek TODO kartı", rows, function(current, item)
			local card: Card = item.card
			backend(current, {op = "kanban-options"}, function(now, data, why)
				if why then now:toast("error", "Hermes panoları alınamadı", why); return end
				local boards: {PickItem} = {}
				for _, board in data.boards do table.insert(boards, {label = board.name, detail = board.slug, slug = board.slug}) end
				if #boards == 0 then now:toast("info", "Kullanılabilir Hermes panosu yok."); return end
				pick(now, "Hermes Kanban panosu", boards, function(dest, board)
					local profiles: {PickItem} = {{label = "Atamadan ekle", name = ""}}
					for _, name in data.profiles do table.insert(profiles, {label = name, name = name}) end
					pick(dest, "Hermes AI profili · atanan kart otomatik çalışır", profiles, function(target, profile)
						local source = if card.key then "Jira kartı: " .. card.key else "Kaynak: Tern TODO.md"
						approve(target, "Hermes Kanban · " .. board.label, "Kanban’a gönder", {
							{label = card.text}, {label = "AI: " .. profile.label},
						}, function(confirmed)
							backend(confirmed, {op = "kanban-create", board = board.slug, assignee = profile.name,
								title = card.text, identity = boardPath .. "\0" .. (card.key or card.text),
								body = source .. "\n\nSeçilen görev: " .. card.title .. "\n\nJira’ya yazma, mesaj gönderme veya cihaz işlemi ayrıca kullanıcı onayı gerektirir.",
							}, function(last, result, sendErr)
								if sendErr then last:toast("error", "Kanban’a eklenemedi", sendErr)
								else last:toast("success", "Hermes Kanban kartı hazır", tostring(result.id or result.task_id)) end
							end)
						end)
					end)
				end)
			end)
		end)
	end)
end

tern.command({id = "pull", title = "Todo · Jira: Jira’dan yenile", run = function(cx) refresh(cx, false, nil) end})
tern.command({id = "changes", title = "Todo · Jira: Değişiklikler", run = function(cx) preview(cx, false) end})
tern.command({id = "fill", title = "Todo · Jira: Doldur", run = function(cx) preview(cx, true) end})
tern.command({id = "kanban", title = "Todo · Jira: AI’a ata / Kanban’a ekle", run = kanban})

tern.carly.export("doldur", {
	sig = "doldur() -> string",
	doc = "Kullanıcı 'doldur' dediğinde özel Todo · Jira önizlemesini açar. Jira’ya yazmaz; kullanıcı kartı ve tam metni seçicide onaylar.",
}, function(cx: WindowCx, _call: ExportCall)
	preview(cx, true)
	return "Özel önizleme istendi; hiçbir kart otomatik doldurulmadı."
end)

tern.chrome.status(function(_pane)
	if #drafts == 0 then return nil end
	return {{text = `Todo · {#drafts} önemli değişiklik`, command = "plugin.todo-jira.changes"}}
end)

local function tick(cx: WindowCx?)
	if cx and cx:window_key() == "" then refresh(cx, true, nil) end
	tern.timer(refreshMs, tick)
end
tern.timer(1000, tick)
