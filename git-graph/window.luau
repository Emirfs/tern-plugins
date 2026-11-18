--!strict
-- Window half: palette commands that open graph panes, the focused terminal's folder for panes that follow
-- it (kv `focus`), and the pickers/prompts a pane asks for (kv `ask` → kv `answer:<pane>`).
local KIND = "git-graph.graph"
local FOLLOWS: { [string]: boolean } = { terminal = true, agent = true }

local focused: number? = nil

local function publish(cwd: string?, pane: number)
	if cwd and cwd ~= "" then
		local cur = tern.kv.get("focus")
		if type(cur) ~= "table" or cur.cwd ~= cwd then
			tern.kv.set("focus", { cwd = cwd, pane = pane })
		end
	end
end

local function pane_info(cx: WindowCx, pane: number): PaneInfo?
	for _, p in cx.session:panes() do
		if p.pane == pane then
			return p
		end
	end
	return nil
end

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	local info = pane_info(cx, ev.pane)
	if info and info.kind and FOLLOWS[info.kind] then
		focused = ev.pane
		publish(info.cwd, ev.pane)
	end
end)

tern.on("cwd", function(ev: CwdEvent, _cx: WindowCx)
	if ev.pane == focused then
		publish(ev.path, ev.pane)
	end
end)

tern.on("window_start", function(cx: WindowCx)
	for _, p in cx.session:panes() do
		if p.focused and p.kind and FOLLOWS[p.kind] then
			focused = p.pane
			publish(p.cwd, p.pane)
		end
	end
end)

local function focused_cwd(cx: WindowCx): string?
	for _, p in cx.session:panes() do
		if p.focused and p.cwd and p.cwd ~= "" then
			return p.cwd
		end
	end
	local f = tern.kv.get("focus")
	return if type(f) == "table" and type(f.cwd) == "string" then f.cwd else nil
end

local function open(cx: WindowCx, args: { string }?)
	if cx:new_block(KIND, args, "beside") == nil then
		cx:toast("error", "Git grafiği açılamadı", "Eklentinin host yarısı yüklenmemiş; `tern plugin list` ile bakın.")
	end
end

tern.command({
	id = "open",
	title = "Git grafiği: yeni panel (odaktaki terminali izler)",
	run = function(cx: WindowCx)
		open(cx, nil)
	end,
})

tern.command({
	id = "here",
	title = "Git grafiği: bu klasörün deposu (sabit)",
	run = function(cx: WindowCx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			cx:toast("info", "Odakta klasörü bilinen bir terminal yok")
			return
		end
		open(cx, { cwd })
	end,
})

tern.command({
	id = "pick",
	title = "Git grafiği: depo seç",
	run = function(cx: WindowCx)
		open(cx, { "--pick" })
	end,
})

-- A pane's question: answered once, by the window it came from (key presses carry no window: the first).
local handled: string? = nil
do
	local a = tern.kv.get("ask")
	handled = if type(a) == "table" then a.id else nil
end

local function answer(pane: number, id: string, value: any)
	tern.kv.set(`answer:{pane}`, { id = id, value = value })
end

local function watch(cx: WindowCx?)
	tern.timer(300, watch)
	local a = tern.kv.get("ask")
	if cx == nil or type(a) ~= "table" or a.id == handled or type(a.id) ~= "string" or type(a.pane) ~= "number" then
		return
	end
	if (a.window or "") ~= cx:window_key() then
		return
	end
	handled = a.id
	local id, pane = a.id :: string, a.pane :: number
	if a.kind == "pick" and type(a.items) == "table" and #a.items > 0 then
		cx:pick({ items = a.items, placeholder = a.placeholder, icon = a.icon }):next(function(item, _err, _cx)
			if item then
				answer(pane, id, item.value)
			end
		end)
	elseif a.kind == "prompt" then
		cx:prompt({ placeholder = a.placeholder, value = a.value }):next(function(text, _err, _cx)
			if text then
				answer(pane, id, text)
			end
		end)
	end
end
tern.timer(300, watch)
