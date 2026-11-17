--!strict
-- Bağımsız sütunlar: satır satır bölünmüş ızgaraları sütunlara çevirir.
--
-- Tern bölmeleri ikili ağaç olarak tutar. (A | B) / (C | D) düzeninde yatay
-- ayraç iki sütunu birden keser: sağdakini yukarı çekince soldaki de gelir.
-- Aynı dört pane (A / C) | (B / D) olarak dizilince her sütunun kendi yatay
-- ayracı olur. Eklenti, sekmenin ağacında her satırında aynı sayıda pane olan
-- bir ızgara (varsayılan en az 2×2, ayarlanır) bulduğu her yerde, sekmenin bir
-- parçası olsa bile, pane'leri taşıyarak onu sütunlara çevirir; programlar
-- kapanmaz. Kendiliğinden: yüklenince açık sekmede, odak değişince, pane
-- açılınca ya da kapanınca (kapatılabilir); palet komutuyla elle de çalışır.

local grid = require("./grid")

local AUTO_KEY = "auto"
-- En küçük ızgara, { rows, cols }: bundan küçükler kendiliğinden çevrilmez.
local MIN_KEY = "min"

local function min_size(): grid.Min
	local ok, value = pcall(tern.kv.get, MIN_KEY)
	return grid.parse_min(if ok then value else nil)
end

-- Sekmedeki en az `min` boyutundaki satır ızgaralarını sütunlara çevirir. Bir
-- taşıma başarısız olursa düzen eski haline döner. Bir şey çevrildiyse true.
local function to_columns(cx: WindowCx, tab: number, min: grid.Min): (boolean, string?)
	local layout = cx.session:layout(tab)
	if layout == nil or layout.zoomed then
		return false, nil
	end
	local grids = grid.find(layout.root, min)
	if #grids == 0 then
		return false, nil
	end
	local snap = cx.layout:snapshot()
	local keep = { focus = false }
	-- Her satırın pane'ini bir üst satırdaki pane'in altına taşı: satır boşalınca
	-- kapanır, her sütun kendi `down` zincirine dönüşür. Taşımalar ızgaranın
	-- kendi yaprakları arasında kaldığı için diğer ızgaraların id'leri geçerli kalır.
	for _, g in grids do
		for i = 2, #g do
			for j, pane in g[i] do
				if not cx.layout:move(pane, g[i - 1][j], "down", keep) then
					cx.layout:restore(snap)
					return false, "pane taşınamadı"
				end
			end
		end
	end
	if layout.focus then
		cx.layout:focus(layout.focus)
	end
	return true, nil
end

local function auto_enabled(): boolean
	local ok, value = pcall(tern.kv.get, AUTO_KEY)
	return not ok or value ~= false
end

local function current_tab(cx: WindowCx): number?
	local pane = cx.session:focused()
	return if pane then cx.session:tab_of(pane) else nil
end

local function on_change(ev: { pane: number }, cx: WindowCx)
	if not auto_enabled() then
		return
	end
	local tab = cx.session:tab_of(ev.pane) or current_tab(cx)
	if tab then
		local _, err = to_columns(cx, tab, min_size())
		if err then
			cx:toast("error", "Bağımsız sütunlar: " .. err)
		end
	end
end

tern.on("pane_created", on_change)
tern.on("pane_closed", function(_ev, cx)
	if not auto_enabled() then
		return
	end
	local tab = current_tab(cx)
	if tab then
		to_columns(cx, tab, min_size())
	end
end)
-- Eklentiden önce kurulmuş düzenler: geçilen sekmede ve yüklenince açık sekmede.
tern.on("focus", function(ev, cx)
	if auto_enabled() then
		to_columns(cx, ev.tab, min_size())
	end
end)
tern.timer(0, function(cx)
	if cx and auto_enabled() then
		local tab = current_tab(cx)
		if tab then
			to_columns(cx, tab, min_size())
		end
	end
end)

tern.command({
	id = "columns",
	title = "Izgarayı sütunlara ayır",
	icon = "columns",
	run = function(cx)
		local tab = current_tab(cx)
		if tab == nil then
			return
		end
		-- Elle istenince ayardaki en küçük boyut değil, her ızgara (en az 2×2).
		local done, err = to_columns(cx, tab, grid.DEFAULT_MIN)
		if err then
			cx:toast("error", "Bağımsız sütunlar: " .. err)
		elseif not done then
			cx:toast("info", "Sekme satır satır bölünmüş bir ızgara değil", "Her satırda aynı sayıda (en az 2) pane olmalı.")
		end
	end,
})

tern.command({
	id = "toggle_auto",
	title = "Bağımsız sütunlar: otomatik çevirmeyi aç/kapat",
	icon = "columns",
	run = function(cx)
		local enabled = not auto_enabled()
		tern.kv.set(AUTO_KEY, enabled)
		cx:toast("info", if enabled then "Otomatik sütun düzeni açık" else "Otomatik sütun düzeni kapalı")
	end,
})

local SIZES = { { 2, 2 }, { 2, 3 }, { 3, 2 }, { 3, 3 } }

tern.command({
	id = "min_size",
	title = "Bağımsız sütunlar: kendiliğinden çevrilecek en küçük ızgara",
	icon = "columns",
	run = function(cx)
		local now = min_size()
		local items: { PickItem } = {}
		for _, s in SIZES do
			table.insert(items, {
				label = string.format("%d satır × %d sütun", s[1], s[2]),
				detail = if s[1] == 2 and s[2] == 2 then "varsayılan" else nil,
				current = now.rows == s[1] and now.cols == s[2],
				rows = s[1],
				cols = s[2],
			})
		end
		cx:pick({ items = items, placeholder = "En küçük ızgara", icon = "columns", action = "seç" }):next(function(item, _err, wcx)
			if item == nil then
				return
			end
			tern.kv.set(MIN_KEY, { rows = item.rows, cols = item.cols })
			if wcx then
				wcx:toast("info", "Kendiliğinden çevrilen en küçük ızgara: " .. item.label)
			end
		end)
	end,
})
