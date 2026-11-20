--!strict
local runner = require("./lib/runner")
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
-- A sync or write in progress. The callback may never arrive once the window closes: the flag expires after a timeout.
local busyUntil = 0
local BUSY_MS = 3 * 60 * 1000
local alerted = ""
local backgroundError = ""
local vaultWarning = ""

local function isBusy(): boolean
	return tern.now() < busyUntil
end

local function setBusy(on: boolean)
	busyUntil = if on then tern.now() + BUSY_MS else 0
end

local function backend(cx: WindowCx, data: any, cb: (WindowCx, any, string?) -> ())
	local ok, err = pcall(function()
		tern.process.run(runner.argv(), {
			cwd = tern.plugin.dir, timeout_ms = runner.TIMEOUT_MS, stdin = tern.json.encode(data), env = runner.env(),
		}, function(result: ProcessResult, fresh: WindowCx?)
			if not fresh then return end
			local reply, why = runner.decode(result)
			cb(fresh, reply, why)
		end)
	end)
	if not ok then
		cb(cx, nil, `Could not start the Todo connection: {err}`)
	end
end

local function readBoard(cx: WindowCx, cb: (WindowCx, {Card}?, {[string]: string}?, string?) -> ())
	cx.board:read(boardPath, {rows = 500, max_chars = 4096}):next(function(snapshot, err, fresh)
		if not fresh then return end
		if not snapshot or snapshot.phase ~= "ready" then
			cb(fresh, nil, nil, err or "The TODO board is not ready yet.")
		elseif snapshot.more > 0 or snapshot.open + snapshot.done > 500 then
			cb(fresh, nil, nil, "The TODO board has more than 500 cards. Not synced, to avoid working with partial data.")
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
		local due: (string | false)? = if edit.due == "" then false else edit.due
		local function complete(result: any, err: string?, current: WindowCx?)
			if not current then return end
			if err or not result then done(current, err or "Could not save the board change."); return end
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
					if err or not result then done(current, err or "Could not edit the card.") else move(current) end
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
			done(fresh, `There is more than one “{lane}” column; sync stopped.`)
		elseif lane and not lanes[lane] then
			fresh.board:add_lane(boardPath, {title = lane}):next(function(id, err, current)
				if not current then return end
				if not id then done(current, err or "Could not create the column."); return end
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
	-- The card notes in the vault are refreshed from Jira; cards with a filled "Jira draft" section become suggestions.
	backend(cx, {op = "memory"}, function(fresh, data, err)
		if not err then
			drafts = data.drafts
			local warning = data.warning or ""
			if warning ~= "" and warning ~= vaultWarning then
				fresh:toast("error", "Todo · Jira memory vault", warning)
			end
			vaultWarning = warning
			local ids = {}
			for _, draft in drafts do table.insert(ids, draft.key .. draft.digest) end
			table.sort(ids)
			local current = table.concat(ids, ":")
			if notify and current ~= "" and current ~= alerted then
				fresh:toast("info", `Todo · Jira: {#drafts} Jira comment drafts ready`, "Preview them with Fill; nothing has been written to Jira yet.")
			end
			alerted = current
			tern.chrome.refresh()
		end
		done(fresh, err)
	end)
end

local function refresh(cx: WindowCx, quiet: boolean, done: ((WindowCx, {Change}, {string}) -> ())?)
	if isBusy() then
		if not quiet then cx:toast("info", "Todo · Jira sync in progress.") end
		return
	end
	setBusy(true)
	local function fail(fresh: WindowCx, err: string)
		setBusy(false)
		if not quiet then
			fresh:toast("error", "Todo · Jira refresh failed", err)
		elseif err ~= backgroundError then
			-- A background sync must not die silently: each new error is shown once.
			backgroundError = err
			fresh:toast("error", "Todo · Jira background sync stopped", err)
		end
	end
	backend(cx, {op = "assigned"}, function(fresh, assigned, err)
		if err then fail(fresh, err); return end
		readBoard(fresh, function(now, cards, lanes, boardErr)
			if not cards or not lanes then fail(now, boardErr or "Could not read the TODO board."); return end
			local edits, changes, conflicts, baseline = sync.plan(assigned, cards, tern.kv.get("jira-baseline") or {})
			applyBoard(now, lanes, edits, function(current, writeErr)
				if writeErr then fail(current, writeErr); return end
				storeBase(baseline)
				issues = assigned
				scanMemory(current, quiet, function(last, memoryErr)
					setBusy(false)
					backgroundError = ""
					if memoryErr and not quiet then last:toast("error", "Could not refresh the memory preview", memoryErr) end
					if done then
						done(last, changes, conflicts)
					elseif not quiet then
						last:toast("success", `{#assigned} Jira cards · {#edits} board updates`, `{#changes} sendable edits · {#conflicts} conflicts`)
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
	if isBusy() then cx:toast("info", "Todo · Jira sync in progress."); return end
	setBusy(true)
	backend(cx, data, function(fresh, reply, err)
		setBusy(false)
		if err then fresh:toast("error", "Could not send to Jira", err) else cb(fresh, reply) end
	end)
end

local function sendChange(cx: WindowCx, change: Change, value: string, name: string)
	local issue = change.issue
	local old = if change.field == "status" then issue.status_name else change.before
	approve(cx, issue.key .. " · Send to Jira", "Send to Jira", {
		{label = "Before: " .. (old ~= "" and old or "—")},
		{label = "After: " .. (name ~= "" and name or "—")},
	}, function(fresh)
		readBoard(fresh, function(current, cards, _, err)
			if not cards then current:toast("error", "Could not read TODO", err); return end
			local _, pending = sync.plan(issues, cards, tern.kv.get("jira-baseline") or {})
			for _, candidate in pending do
				if candidate.issue.id == issue.id and candidate.field == change.field and candidate.before == change.before
					and candidate.value == change.value and candidate.card.id == change.card.id then
					jiraWrite(current, {op = "change", key = issue.key, id = issue.id, field = change.field,
						before = change.before, value = value, lane = change.value}, function(last, _)
						last:toast("success", issue.key .. " updated in Jira.")
						refresh(last, true, nil)
					end)
					return
				end
			end
			current:toast("error", "The edit changed; preview it again.")
		end)
	end)
end

local function showChange(cx: WindowCx, change: Change)
	if change.field ~= "status" then sendChange(cx, change, change.value, change.value); return end
	local issue = change.issue
	backend(cx, {op = "transitions", key = issue.key, id = issue.id, before = change.before, lane = change.value}, function(fresh, data, err)
		if err then fresh:toast("error", "Could not get the Jira statuses", err); return end
		local rows: {PickItem} = {}
		for _, t in data do table.insert(rows, {label = t.name, detail = t.action, id = t.id}) end
		if #rows == 0 then fresh:toast("info", `No Jira transition to this column for {issue.key}.`); return end
		pick(fresh, issue.key .. " · Jira status", rows, function(current, row)
			sendChange(current, change, row.id, row.label)
		end)
	end)
end

local function showDraft(cx: WindowCx, draft: Draft)
	-- Draft Markdown: the line structure is kept, long lines are wrapped at 80 characters.
	local details: {PickItem} = {}
	for raw in string.gmatch(draft.text .. "\n", "([^\n]*)\n") do
		local line = ""
		for word in string.gmatch(raw, "%S+") do
			if #line + #word > 80 and line ~= "" then
				table.insert(details, {label = line})
				line = "  "
			end
			line ..= (if line == "" or line == "  " then "" else " ") .. word
		end
		if line ~= "" and line ~= "  " then table.insert(details, {label = line}) end
	end
	approve(cx, draft.key .. " · Draft preview · Jira progress comment", "Fill · Send this text to Jira", details, function(fresh)
		for _, current in drafts do
			if current.id == draft.id and current.digest == draft.digest then
				jiraWrite(fresh, {op = "comment", key = draft.key, id = draft.id, text = draft.text}, function(last, _)
					-- The sent draft was cleared in the vault note; the next sync adds it to "Sent to Jira".
					for i, item in drafts do if item == current then table.remove(drafts, i); break end end
					tern.chrome.refresh()
					last:toast("success", draft.key .. " progress comment verified in Jira.")
				end)
				return
			end
		end
		fresh:toast("info", "This preview changed; open it again.")
	end)
end

local function preview(cx: WindowCx, memoryOnly: boolean)
	refresh(cx, false, function(fresh, changes, conflicts)
		local rows: {PickItem} = {}
		for _, draft in drafts do
			table.insert(rows, {label = draft.key, detail = draft.text, group = "Memory · draft previews", draft = draft})
		end
		if not memoryOnly then
			for _, change in changes do
				local label = if change.field == "title" then "Title" elseif change.field == "due" then "Due date" else "Status"
				table.insert(rows, {label = change.issue.key .. " · " .. label, detail = change.value, group = "Can be sent to Jira", change = change})
			end
			for _, conflict in conflicts do table.insert(rows, {label = conflict, group = "Conflicts · nothing was written"}) end
		end
		if #rows == 0 then fresh:toast("info", "No notable changes to send."); return end
		pick(fresh, "Todo · Jira · Changes", rows, function(current, row)
			if row.draft then showDraft(current, row.draft) elseif row.change then showChange(current, row.change) end
		end)
	end)
end

local function assignCard(cx: WindowCx, card: Card)
	backend(cx, {op = "kanban-options"}, function(now, data, why)
		if why then now:toast("error", "Could not get the Hermes boards", why); return end
		local boards: {PickItem} = {}
		for _, board in data.boards do table.insert(boards, {label = board.name, detail = board.slug, slug = board.slug}) end
		if #boards == 0 then now:toast("info", "No Hermes board available."); return end
		local function withBoard(dest: WindowCx, board: PickItem)
			local profiles: {PickItem} = {{label = "Add without an assignee", name = ""}}
			for _, name in data.profiles do table.insert(profiles, {label = name, name = name}) end
			pick(dest, "Hermes AI profile · an assigned card runs automatically", profiles, function(target, profile)
				local source = if card.key then "Jira card: " .. card.key else "Source: Tern TODO.md"
				local details: {PickItem} = {{label = card.text}, {label = "AI: " .. profile.label}}
				if card.key then
					table.insert(details, {label = "The Jira description and the last 3 comments are added to the task"})
				end
				approve(target, "Hermes Kanban · " .. board.label, "Send to Kanban", details, function(confirmed)
					backend(confirmed, {op = "kanban-create", board = board.slug, assignee = profile.name, key = card.key,
						title = card.text, identity = boardPath .. "\0" .. (card.key or card.text),
						body = source .. "\n\nSelected task: " .. card.title .. "\n\nWriting to Jira, sending messages or any device action needs separate user approval.",
					}, function(last, result, sendErr)
						if sendErr then last:toast("error", "Could not add to Kanban", sendErr); return end
						local status = tostring(result.status or "?")
						-- For the same card, profile and context Hermes does not open a new task; it returns the existing one.
						if status == "done" or status == "blocked" or status == "archived" then
							last:toast("info", `This task already exists: {result.id} ({status})`, "Unless the card has a new comment or description, Hermes returns the same task.")
						else
							last:toast("success", "Hermes Kanban task ready", `{result.id} · {status}` .. (if result.assignee then ` · {result.assignee}` else ""))
						end
					end)
				end)
			end)
		end
		-- With a single board the picker is not shown.
		if #boards == 1 then withBoard(now, boards[1]) else pick(now, "Hermes Kanban board", boards, withBoard) end
	end)
end

local function kanban(cx: WindowCx, key: string?)
	readBoard(cx, function(fresh, cards, _, err)
		if not cards then fresh:toast("error", "Could not read TODO", err); return end
		if key then
			for _, card in cards do
				if card.key == key then assignCard(fresh, card); return end
			end
			-- A Jira card missing from the board (e.g. deleted locally): the Jira context completes its title.
			assignCard(fresh, {id = "", text = `[{key}]`, title = key, due = "", lane = "", key = key})
			return
		end
		local rows: {PickItem} = {}
		for _, card in cards do table.insert(rows, {label = card.text, detail = card.lane, card = card}) end
		if #rows == 0 then fresh:toast("info", "No TODO card to assign."); return end
		pick(fresh, "TODO card to send to Hermes Kanban", rows, function(current, item)
			assignCard(current, item.card)
		end)
	end)
end

local PANE_KIND = "todo-jira.board"

local function openPane(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if pane.block == PANE_KIND and not pane.parked then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(PANE_KIND, nil, "beside") == nil then
		cx:toast("error", "Could not open the Jira pane", "The plugin's host half is not loaded; check its state with `tern plugin list`.")
	end
end

tern.command({id = "pull", title = "Todo · Jira: Refresh from Jira", run = function(cx) refresh(cx, false, nil) end})
tern.command({id = "board", title = "Todo · Jira: Jira pane (cards and comments)", run = openPane})
tern.command({id = "changes", title = "Todo · Jira: Changes", run = function(cx) preview(cx, false) end})
tern.command({id = "fill", title = "Todo · Jira: Fill", run = function(cx) preview(cx, true) end})
tern.command({id = "kanban", title = "Todo · Jira: Assign to AI / Add to Kanban", run = function(cx) kanban(cx, nil) end})

-- The Jira pane's right-click "Hand to AI" request (the host half writes it to kv). A request left over at startup is stale and is ignored.
local handledRequest: string? = nil
do
	local req = tern.kv.get("ai-request")
	handledRequest = if type(req) == "table" then req.id else nil
end

local function watchRequests(cx: WindowCx?)
	tern.timer(700, watchRequests)
	local req = tern.kv.get("ai-request")
	if cx == nil or type(req) ~= "table" or req.id == handledRequest or type(req.key) ~= "string" then return end
	if (req.window or "") ~= cx:window_key() then return end
	handledRequest = req.id
	kanban(cx, req.key)
end
tern.timer(700, watchRequests)

tern.carly.export("fill", {
	sig = "fill() -> string",
	doc = "Opens the private Todo · Jira draft preview when the user says 'fill'. It does not write to Jira; the user approves the card and the full text in the picker.",
}, function(cx: WindowCx, _call: ExportCall)
	preview(cx, true)
	return "Draft preview requested; no card was filled in automatically."
end)

tern.chrome.status(function(_pane)
	if #drafts == 0 then return nil end
	return {{text = `Todo · {#drafts} to review`, command = "plugin.todo-jira.changes"}}
end)

local function tick(cx: WindowCx?)
	if cx and cx:window_key() == "" then refresh(cx, true, nil) end
	tern.timer(refreshMs, tick)
end
tern.timer(1000, tick)
