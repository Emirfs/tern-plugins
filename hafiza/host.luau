--!strict
-- `panel` block: the vault's suggestion inbox (inbox/) and today's note. Accept / Reject run the
-- vault's `.tools/inbox.py`, which edits the note and commits. This block never writes to the vault itself.
-- Keys: r refresh, a accept the selected suggestion, x reject it.

local ui = tern.ui

local REFRESH_MS = 60 * 1000
local ACT_ACCEPT = "Accept"
local ACT_REJECT = "Reject"
local ACT_OPEN = "Open target note"
local KIND_LABEL: { [string]: string } = {
	summary = "summary", decision = "decision", lesson = "lesson", profile = "profile", rule = "rule idea", open = "open task",
}

type Proposal = { file: string, target: string, kind: string, source: string, why: string, text: string, when: string }
type State = {
	cx: BlockCx,
	items: { Proposal },
	today: string,
	loading: boolean,
	busy: boolean,
	err: string?,
	selected: string?,
	closed: boolean,
}

local function vault(): string
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME") or ""
	return tern.getenv("HAFIZA_DIR") or (home .. "/GitHub/araclar/hafiza")
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function render(state: State)
	if not state.closed and not pcall(state.cx.render, state.cx) then
		state.closed = true
	end
end

-- `inbox.py <args>` → (data, error).
local function run(args: { string }, done: (any, string?) -> ())
	local argv = { tern.getenv("HAFIZA_PYTHON") or "python", "-B", "inbox.py" }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { cwd = vault() .. "/.tools", timeout_ms = 60000, env = { PYTHONIOENCODING = "utf-8" } },
			function(result: ProcessResult, _)
				local decoded, reply = pcall(tern.json.decode, result.stdout)
				if result.status ~= 0 or not decoded or type(reply) ~= "table" then
					done(nil, "Vault tool did not respond: " .. string.sub(result.stderr, -200))
				else
					done(reply.data, reply.error)
				end
			end)
	end)
	if not ok then
		done(nil, `Could not start Python: {err}`)
	end
end

local function refresh(state: State)
	if state.loading or state.closed then
		return
	end
	state.loading = true
	run({ "list" }, function(items, err)
		run({ "today" }, function(today, err2)
			state.loading = false
			state.err = err or err2
			if type(items) == "table" then
				state.items = items
			end
			state.today = if type(today) == "table" then today.text or "" else ""
			local found = false
			for _, it in state.items do
				found = found or it.file == state.selected
			end
			if not found then
				state.selected = if state.items[1] then state.items[1].file else nil
			end
			render(state)
		end)
	end)
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

local function find(state: State, file: string?): Proposal?
	for _, it in state.items do
		if it.file == file then
			return it
		end
	end
	return nil
end

local function act(state: State, name: string, file: string?)
	local item = find(state, file)
	if item == nil or state.busy then
		return
	end
	if name == ACT_OPEN then
		state.cx:open(vault() .. "/" .. item.target .. ".md")
		return
	end
	local verb = if name == ACT_ACCEPT then "accept" elseif name == ACT_REJECT then "reject" else nil
	if verb == nil then
		return
	end
	state.busy = true
	run({ verb, item.file }, function(result, err)
		state.busy = false
		if err then
			state.cx:toast("error", "Memory: action failed", err)
		else
			local what = if verb == "accept" then `applied to {item.target}` else "suggestion deleted"
			state.cx:toast("success", "Memory: " .. what, if result and result.warning then result.warning else nil)
		end
		refresh(state)
	end)
end

local function inbox_table(state: State): Node
	local rows: { TableRow } = {}
	for _, it in state.items do
		table.insert(rows, {
			id = it.file,
			menu = { ACT_ACCEPT, ACT_REJECT, ACT_OPEN },
			cells = {
				ui.span(it.when, "muted"),
				ui.span(it.target, "mono"),
				{ badge = { text = KIND_LABEL[it.kind] or it.kind, tone = if it.kind == "rule" then "warning" else "accent" } },
				it.text,
			},
		})
	end
	return with(ui.table({
		{ id = "when", head = "When", priority = -1 },
		{ id = "target", head = "Target", mono = true },
		{ id = "kind", head = "Kind" },
		{ id = "text", head = "Suggestion", grow = 1 },
	}, rows, {
		selectable = true,
		selected = state.selected,
		empty = if state.loading then "Loading…" else "No pending suggestions.",
	}), { key = "inbox" })
end

local function detail(item: Proposal): Node
	local children: { Node } = {
		ui.md(item.text),
		ui.kv({ { "Why", item.why }, { "Source", ui.span(item.source, "mono") }, { "File", ui.span(item.file, "mono") } }),
	}
	if item.kind == "rule" then
		table.insert(children, ui.text({ ui.span("Rule ideas do not go to the rule files automatically; if accepted they are written to rules-accepted.md and you move them to agent-rules yourself.", "muted") }))
	end
	local buttons = ui.row({
		ui.button(ACT_ACCEPT, { variant = "primary", size = "sm", keys = { "a" }, actions = { click = "accept" } }),
		ui.button(ACT_REJECT, { variant = "danger", size = "sm", keys = { "x" }, actions = { click = "reject" } }),
	})
	table.insert(children, buttons)
	local head: { Span | string } = { ui.span(KIND_LABEL[item.kind] or item.kind, "strong"), " · " .. item.target }
	return with(ui.card(head, children, {
		meta = item.when,
	}), { key = "detail:" .. item.file })
end

tern.block.define("panel", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		local state: State = {
			cx = cx, items = {}, today = "", loading = false, busy = false, err = nil, selected = nil, closed = false,
		}
		refresh(state)
		schedule(state)
		return state
	end,

	title = function(state: State): string?
		return if #state.items > 0 then `Memory · {#state.items}` else "Memory"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local children: { Node } = {
			with(ui.text({
				ui.span(`{#state.items} suggestions pending`, "muted"),
				ui.span("   r refresh · a accept · x reject · right-click: open target note", "dim"),
			}), { key = "status" }),
		}
		if state.err then
			table.insert(children, with(ui.text({ ui.span("⚠ " .. state.err, "warning") }), { key = "err" }))
		end
		table.insert(children, inbox_table(state))
		local item = find(state, state.selected)
		if item then
			table.insert(children, detail(item))
		end
		local today = if state.today ~= "" then state.today else "_No entry for today yet; the collector writes it every evening at 20:30._"
		table.insert(children, with(ui.section("Today", { ui.md(today) }), { key = "today" }))
		return { main = ui.col(children) }
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "select" and type(ev.item) == "string" then
			state.selected = ev.item
		elseif ev.ev == "action" and ev.act == "accept" then
			act(state, ACT_ACCEPT, state.selected)
		elseif ev.ev == "action" and ev.act == "reject" then
			act(state, ACT_REJECT, state.selected)
		elseif ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, if type(ev.item) == "string" then ev.item else state.selected)
		end
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "r" then
			refresh(state)
		elseif k == "a" then
			act(state, ACT_ACCEPT, state.selected)
		elseif k == "x" then
			act(state, ACT_REJECT, state.selected)
		else
			return false
		end
		return true
	end,
})
