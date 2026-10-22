--!strict
-- Bağımsız sütunlar: satır satır bölünmüş bir ızgarayı sütunlara çevirir.
--
-- Tern bölmeleri ikili ağaç olarak tutar. (A | B) / (C | D) düzeninde yatay
-- ayraç iki sütunu birden keser: sağdakini yukarı çekince soldaki de gelir.
-- Aynı dört pane (A / C) | (B / D) olarak dizilince her sütunun kendi yatay
-- ayracı olur. Eklenti, her satırda aynı sayıda pane olan bir ızgarayı
-- (en az 2×2) pane'leri taşıyarak sütunlara çevirir; programlar kapanmaz.
-- Bir pane açılınca ya da kapanınca o sekmeye kendiliğinden uygulanır
-- (kapatılabilir), palet komutuyla elle de çalıştırılır.

local AUTO_KEY = "auto"

-- `dir` yönündeki iç içe bölmeleri sırasıyla düzleştirir: (A | (B | C)) → A, B, C.
local function chain(t: TabTree, dir: string, out: { TabTree })
	if t.pane == nil and t.split == dir and t[1] and t[2] then
		chain(t[1], dir, out)
		chain(t[2], dir, out)
	else
		table.insert(out, t)
	end
end

-- Kök satırlara (`down`) bölünmüşse ve her satır aynı sayıda (≥2) yan yana
-- pane'den oluşuyorsa pane id'lerini satır satır döndürür; değilse nil.
local function rows_grid(root: TabTree): { { number } }?
	if root.pane ~= nil or root.split ~= "down" then
		return nil
	end
	local rows: { TabTree } = {}
	chain(root, "down", rows)
	if #rows < 2 then
		return nil
	end
	local grid: { { number } } = {}
	local width: number? = nil
	for i, row in rows do
		local cells: { TabTree } = {}
		chain(row, "right", cells)
		if #cells < 2 or (width ~= nil and #cells ~= width) then
			return nil
		end
		width = #cells
		local ids: { number } = {}
		for _, cell in cells do
			local pane = cell.pane
			if pane == nil then
				return nil
			end
			table.insert(ids, pane)
		end
		grid[i] = ids
	end
	return grid
end

-- Sekmedeki satır ızgarasını sütunlara çevirir. Bir taşıma başarısız olursa
-- düzen eski haline döner. Çevrildiyse true.
local function to_columns(cx: WindowCx, tab: number): (boolean, string?)
	local layout = cx.session:layout(tab)
	if layout == nil or layout.zoomed then
		return false, nil
	end
	local grid = rows_grid(layout.root)
	if grid == nil then
		return false, nil
	end
	local snap = cx.layout:snapshot()
	local keep = { focus = false }
	-- Her satırın pane'ini bir üst satırdaki pane'in altına taşı: satır boşalınca
	-- kapanır, her sütun kendi `down` zincirine dönüşür.
	for i = 2, #grid do
		for j, pane in grid[i] do
			if not cx.layout:move(pane, grid[i - 1][j], "down", keep) then
				cx.layout:restore(snap)
				return false, "pane taşınamadı"
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
		local _, err = to_columns(cx, tab)
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
		to_columns(cx, tab)
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
		local done, err = to_columns(cx, tab)
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
