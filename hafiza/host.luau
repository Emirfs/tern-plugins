--!strict
-- `panel` bloğu: kasanın öneri kutusu (inbox/) ve günün notu. Kabul et / Reddet kasadaki
-- `.tools/inbox.py`yi çalıştırır; o da notu değiştirip commit eder. Bu blok kasaya kendisi yazmaz.
-- Tuşlar: r yenile, a seçili öneriyi kabul et, x reddet.

local ui = tern.ui

local REFRESH_MS = 60 * 1000
local ACT_ACCEPT = "Kabul et"
local ACT_REJECT = "Reddet"
local ACT_OPEN = "Hedef notu aç"
local KIND_LABEL: { [string]: string } = {
	summary = "özet", decision = "karar", lesson = "ders", profile = "profil", rule = "kural fikri", open = "açık iş",
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
					done(nil, "Kasa aracı yanıt vermedi: " .. string.sub(result.stderr, -200))
				else
					done(reply.data, reply.error)
				end
			end)
	end)
	if not ok then
		done(nil, `Python başlatılamadı: {err}`)
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
			state.cx:toast("error", "Hafıza: işlem yapılamadı", err)
		else
			local what = if verb == "accept" then `{item.target} notuna işlendi` else "öneri silindi"
			state.cx:toast("success", "Hafıza: " .. what, if result and result.warning then result.warning else nil)
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
		{ id = "when", head = "Ne zaman", priority = -1 },
		{ id = "target", head = "Hedef", mono = true },
		{ id = "kind", head = "Tür" },
		{ id = "text", head = "Öneri", grow = 1 },
	}, rows, {
		selectable = true,
		selected = state.selected,
		empty = if state.loading then "Okunuyor…" else "Bekleyen öneri yok.",
	}), { key = "inbox" })
end

local function detail(item: Proposal): Node
	local children: { Node } = {
		ui.md(item.text),
		ui.kv({ { "Neden", item.why }, { "Kaynak", ui.span(item.source, "mono") }, { "Dosya", ui.span(item.file, "mono") } }),
	}
	if item.kind == "rule" then
		table.insert(children, ui.text({ ui.span("Kural fikri kural dosyalarına otomatik gitmez; kabul edilirse rules-accepted.md'ye yazılır, agent-rules'a sen taşırsın.", "muted") }))
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
		return if #state.items > 0 then `Hafıza · {#state.items}` else "Hafıza"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local children: { Node } = {
			with(ui.text({
				ui.span(`{#state.items} öneri bekliyor`, "muted"),
				ui.span("   r yenile · a kabul · x reddet · sağ tık: hedef notu aç", "dim"),
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
		local today = if state.today ~= "" then state.today else "_Bugün için henüz kayıt yok; toplayıcı her akşam 20:30'da yazar._"
		table.insert(children, with(ui.section("Bugün", { ui.md(today) }), { key = "today" }))
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
