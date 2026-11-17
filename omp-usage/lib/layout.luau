--!strict
-- Pane boyutuna göre görünüm seçimi. Saf: yalnız sütun/satır sayılarıyla
-- çalışır; görünüm hiçbir boyutta kaydırma istemez.

local layout = {}

-- Yığılı görünüm: en az bu kadar sütun; bundan genişte yüzde ve süre sözcüklerle yazılır.
layout.ROOMY_MIN_COLS = 44
layout.ROOMY_WIDE_COLS = 64
-- Yığılı görünümde sağlayıcı grupları arasındaki ayraç, satır cinsinden.
layout.GROUP_GAP_LINES = 1

-- Blok satırları pane hücrelerinden ~%40 daha uzun; bölge kenar boşlukları ~2 hücre.
layout.ROW_CELLS = 1.4
layout.CHROME_CELLS = 2
-- Sütun genişlikleri, hücre: hesap etiketi, pencere başına kalan+sıfırlanma,
-- çubuk, yalnız kalan yüzdesi.
layout.ACCOUNT_COLS = 18
layout.WINDOW_COLS = 15
layout.BAR_COLS = 15
layout.PCT_COLS = 7
-- Bunun altında tablo yerine liste: etiket kırpılır, yüzdeler sağda kalır.
layout.TINY_COLS = 30
-- Durum satırındaki tuş ipucu bundan dar pane'de gösterilmez.
layout.HINT_COLS = 50

export type Layout = {
	bars: boolean,
	resets: boolean,
	narrow: boolean,
	tiny: boolean,
	collapse: boolean,
	table_lines: number,
	capacity: number,
}

-- Sağlayıcı başına hesap sayıları: görünüm yalnız bunlara bakar.
export type Shape = { number }

--- Tablo/liste için ne sığar: dar pane'de önce çubuklar, sonra sıfırlanma
--- sütunları, en darda e-postalar düşer ve liste görünümüne geçilir; kısa ya da
--- çok dar pane'de çok hesaplı sağlayıcılar tek toplam satırına iner.
function layout.table_for(shape: Shape, windows: number, extra_lines: number, cols: number, rows: number): Layout
	local lines = 0
	for _, n in shape do
		lines += if n > 1 then n + 1 else 1
	end
	local capacity = math.floor((rows - layout.CHROME_CELLS) / layout.ROW_CELLS)
	local tiny = cols < layout.TINY_COLS
	local collapse = tiny or 1 + lines + extra_lines > capacity
	return {
		bars = cols >= layout.ACCOUNT_COLS + windows * (layout.WINDOW_COLS + layout.BAR_COLS),
		resets = cols >= layout.ACCOUNT_COLS + windows * layout.WINDOW_COLS,
		narrow = cols < layout.ACCOUNT_COLS + windows * layout.PCT_COLS,
		tiny = tiny,
		collapse = collapse,
		table_lines = 1 + (if collapse then #shape else lines),
		capacity = capacity,
	}
end

--- Yığılı görünümün satır sayısı (tablo satırı biriminde).
function layout.roomy_lines(shape: Shape, windows: number, status_count: number): number
	local n = 0
	for _, k in shape do
		n += if k == 1 then 1 + windows else 1 + k * (1 + windows)
	end
	return n + (#shape - 1) * layout.GROUP_GAP_LINES + status_count
end

--- Yığılı görünüm sığıyor mu; sığıyorsa geniş (sözcüklü) biçim mi.
function layout.roomy(shape: Shape, windows: number, status_count: number, cols: number, rows: number): (boolean, boolean)
	if cols < layout.ROOMY_MIN_COLS then
		return false, false
	end
	if layout.CHROME_CELLS + layout.roomy_lines(shape, windows, status_count) * layout.ROW_CELLS > rows then
		return false, false
	end
	return true, cols >= layout.ROOMY_WIDE_COLS
end

return layout
