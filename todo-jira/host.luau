--!strict
-- `board` block: the Jira cards assigned to this account and every comment on each (author, date, text).
-- Read-only: it never writes to Jira. The right-click "Hand to AI" request reaches the window half through kv
-- (the picker and the approval exist only there); "Open in Jira" opens the card in the browser.
-- Keys: r refresh, d show/hide finished cards, enter open the selected card in Jira.

local runner = require("./lib/runner")

local ui = tern.ui

local REFRESH_MS = 5 * 60 * 1000
local LANE_ORDER: { [string]: number } = { Doing = 1, Todo = 2, Done = 3 }
local LANE_TONE: { [string]: string } = { Doing = "accent", Todo = "muted", Done = "success" }
local ACT_AI = "Hand to AI"
local ACT_OPEN = "Open in Jira"
local ACT_COPY = "Copy link"
local ACT_NOTE = "Open memory note"

type Comment = { id: string, author: string, mine: boolean, created: string, edited: boolean, text: string, url: string }
type Issue = {
	key: string, title: string, lane: string, status_name: string, updated: string,
	url: string, description: string, comments: { Comment },
	-- The card note in the vault (`jira/<KEY>.md`): its body and its path.
	memory: string?, note: string?,
}
type State = {
	cx: BlockCx,
	issues: { Issue },
	loading: boolean,
	err: string?,
	fetched: number?,
	selected: string?,
	showDone: boolean,
	closed: boolean,
}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function render(state: State)
	-- A pane closed with Tern's × button has no hook: if drawing fails, end the chain.
	if not state.closed and not pcall(state.cx.render, state.cx) then
		state.closed = true
	end
end

local function visible(state: State): { Issue }
	local out: { Issue } = {}
	for _, issue in state.issues do
		if state.showDone or issue.lane ~= "Done" then
			table.insert(out, issue)
		end
	end
	table.sort(out, function(a, b)
		local la, lb = LANE_ORDER[a.lane] or 9, LANE_ORDER[b.lane] or 9
		if la ~= lb then
			return la < lb
		end
		return a.updated > b.updated
	end)
	return out
end

local function find(state: State, key: string?): Issue?
	for _, issue in state.issues do
		if issue.key == key then
			return issue
		end
	end
	return nil
end

local function refresh(state: State)
	if state.loading or state.closed then
		return
	end
	-- The first call happens in `init`: nothing is drawn here, the view already shows `loading`.
	state.loading = true
	local ok, err = pcall(function()
		tern.process.run(runner.argv(), {
			cwd = tern.plugin.dir, timeout_ms = runner.TIMEOUT_MS, env = runner.env(), stdin = '{"op":"overview"}',
		}, function(result: ProcessResult, _)
			state.loading = false
			local data, why = runner.decode(result)
			if why or type(data) ~= "table" then
				state.err = why or "Could not read the Jira reply."
			else
				state.issues = data
				state.err = nil
				state.fetched = os.time()
				local shown = visible(state)
				local current = find(state, state.selected)
				if current == nil or (current.lane == "Done" and not state.showDone) then
					state.selected = if shown[1] then shown[1].key else nil
				end
			end
			render(state)
		end)
	end)
	if not ok then
		state.loading = false
		state.err = `Could not start Python: {err}`
	end
end

local function schedule(state: State)
	tern.timer(REFRESH_MS, function()
		if state.closed then
			return
		end
		refresh(state)
		schedule(state)
	end)
end

local function last_comment(issue: Issue): string
	local c = issue.comments[#issue.comments]
	return if c then string.sub(c.created, 1, 10) else "—"
end

local function issue_table(state: State, issues: { Issue }): Node
	local rows: { TableRow } = {}
	for _, issue in issues do
		local mine = 0
		for _, c in issue.comments do
			if c.mine then
				mine += 1
			end
		end
		table.insert(rows, {
			id = issue.key,
			menu = { ACT_AI, ACT_OPEN, ACT_NOTE, ACT_COPY },
			cells = {
				ui.span(issue.key, "mono"),
				issue.title,
				{ text = issue.status_name, dot = LANE_TONE[issue.lane] or "muted" },
				if #issue.comments == 0 then ui.span("0", "muted") else `{#issue.comments}` .. (if mine > 0 and mine < #issue.comments then ` ({mine} yours)` else ""),
				ui.span(last_comment(issue), "muted"),
			},
		})
	end
	return with(ui.table({
		{ id = "key", head = "Card", mono = true },
		{ id = "title", head = "Title", grow = 1 },
		{ id = "status", head = "Status", priority = -1 },
		{ id = "comments", head = "Comments", align = "end" },
		{ id = "last", head = "Last comment", priority = -2 },
	}, rows, {
		selectable = true,
		selected = state.selected,
		empty = if state.loading then "Reading Jira…" else "No open cards assigned to this account.",
	}), { key = "issues" })
end

local function detail(issue: Issue): Node
	local children: { Node } = {}
	if issue.memory and issue.memory ~= "" then
		table.insert(children, with(ui.section("Memory · jira/" .. issue.key .. ".md", { ui.md(issue.memory) }), { key = "memory" }))
	end
	if issue.description ~= "" then
		table.insert(children, with(ui.section("Description", { ui.md(issue.description) }), { key = "desc", collapsed = true }))
	end
	if #issue.comments == 0 then
		table.insert(children, ui.text({ ui.span("This card has no comments.", "muted") }))
	end
	-- Newest comment on top: a card's latest state is visible at a glance.
	for i = #issue.comments, 1, -1 do
		local c = issue.comments[i]
		local head: { Span | string } = { ui.span(c.author, "strong") }
		if c.mine then
			table.insert(head, ui.span(" · you", "accent"))
		end
		local meta = c.created .. (if c.edited then " · edited" else "")
		table.insert(children, with(ui.card(head, { ui.md(c.text) }, { meta = meta }), { key = "c" .. c.id }))
	end
	local title: { Span | string } = { ui.span(issue.key, "mono"), " " .. issue.title }
	return with(ui.card(title, children, {
		meta = `{issue.status_name} · {#issue.comments} comments`,
	}), { key = "detail:" .. issue.key })
end

local function status_line(state: State, issues: { Issue }): Node
	local done = 0
	for _, issue in state.issues do
		if issue.lane == "Done" then
			done += 1
		end
	end
	local spans: { Span | string } = { ui.span(`{#issues} cards`, "muted") }
	if not state.showDone and done > 0 then
		table.insert(spans, ui.span(` · {done} finished hidden`, "muted"))
	end
	if state.loading then
		table.insert(spans, ui.span(" · refreshing", "muted"))
	elseif state.fetched then
		table.insert(spans, ui.span(" · " .. os.date("%H:%M", state.fetched), "muted"))
	end
	table.insert(spans, ui.span("   r refresh · d finished · right-click: Hand to AI", "dim"))
	return with(ui.text(spans), { key = "status" })
end

local function request_ai(state: State, key: string, window: string?)
	-- The picker and the approval exist only in the window half; the request goes through kv and the window handles each `id` once.
	tern.kv.set("ai-request", { id = string.format("%.3f", tern.now()), key = key, window = window })
	state.cx:toast("info", key .. " · Hand to AI", "Opening the board and profile picker in the window.")
end

local function act(state: State, name: string, key: string?, window: string?)
	local issue = find(state, key)
	if issue == nil then
		return
	end
	if name == ACT_AI then
		request_ai(state, issue.key, window)
	elseif name == ACT_OPEN then
		state.cx:open(issue.url, if window then { window = window } else nil)
	elseif name == ACT_COPY then
		state.cx:copy(issue.url)
	elseif name == ACT_NOTE and issue.note then
		state.cx:open(issue.note, if window then { window = window } else nil)
	end
end

tern.block.define("board", {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local state: State = {
			cx = cx,
			issues = {},
			loading = false,
			err = nil,
			fetched = nil,
			selected = if type(saved) == "table" and type(saved.selected) == "string" then saved.selected else nil,
			showDone = type(saved) == "table" and saved.showDone == true,
			closed = false,
		}
		refresh(state)
		schedule(state)
		return state
	end,

	title = function(state: State): string?
		local open = 0
		for _, issue in state.issues do
			if issue.lane ~= "Done" then
				open += 1
			end
		end
		return if open > 0 then `Jira · {open}` else "Jira"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local issues = visible(state)
		local children: { Node } = { status_line(state, issues) }
		if state.err then
			table.insert(children, with(ui.text({ ui.span("⚠ " .. state.err, "warning") }), { key = "err" }))
		end
		if state.loading and #state.issues == 0 then
			table.insert(children, ui.progress(nil, "Reading Jira cards and comments"))
		else
			table.insert(children, issue_table(state, issues))
			local selected = find(state, state.selected)
			if selected then
				table.insert(children, detail(selected))
			end
		end
		return { main = ui.col(children) }
	end,

	save = function(state: State): any
		return { selected = state.selected, showDone = state.showDone }
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "select" and type(ev.item) == "string" then
			state.selected = ev.item
		elseif ev.ev == "activate" and type(ev.item) == "string" then
			act(state, ACT_OPEN, ev.item, ev.window)
		elseif ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, if type(ev.item) == "string" then ev.item else state.selected, ev.window)
		end
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "r" then
			refresh(state)
		elseif k == "d" then
			state.showDone = not state.showDone
		elseif k == "enter" and state.selected then
			act(state, ACT_OPEN, state.selected, nil)
		else
			return false
		end
		return true
	end,
})
