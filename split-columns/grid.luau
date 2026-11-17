--!strict
-- Sekme ağacında satır satır bölünmüş ızgaraları bulur. Saf: yalnız düzen
-- ağacına (`TabTree`) bakar, test edilebilir.

local grid = {}

-- Çevrilecek en küçük ızgara: satır sayısı × satır başına pane.
export type Min = { rows: number, cols: number }

local DEFAULT_MIN: Min = { rows = 2, cols = 2 }
grid.DEFAULT_MIN = DEFAULT_MIN

-- `dir` yönündeki iç içe bölmeleri sırasıyla düzleştirir: (A | (B | C)) → A, B, C.
local function chain(t: TabTree, dir: string, out: { TabTree })
	if t.pane == nil and t.split == dir and t[1] and t[2] then
		chain(t[1], dir, out)
		chain(t[2], dir, out)
	else
		table.insert(out, t)
	end
end

--- Düğüm satırlara (`down`) bölünmüşse, en az `min.rows` satırı varsa ve her
--- satır aynı sayıda (en az `min.cols`) yan yana pane'den oluşuyorsa pane
--- id'lerini satır satır döndürür; değilse nil.
function grid.rows_grid(node: TabTree, min: Min): { { number } }?
	if node.pane ~= nil or node.split ~= "down" then
		return nil
	end
	local rows: { TabTree } = {}
	chain(node, "down", rows)
	if #rows < math.max(2, min.rows) then
		return nil
	end
	local out: { { number } } = {}
	local width: number? = nil
	for i, row in rows do
		local cells: { TabTree } = {}
		chain(row, "right", cells)
		if #cells < math.max(2, min.cols) or (width ~= nil and #cells ~= width) then
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
		out[i] = ids
	end
	return out
end

--- Ağaçtaki bütün satır ızgaraları; bir ızgaranın içine inilmez.
function grid.find(node: TabTree, min: Min, out: { { { number } } }?): { { { number } } }
	local found = out or {}
	if node.pane ~= nil then
		return found
	end
	local g = grid.rows_grid(node, min)
	if g then
		table.insert(found, g)
		return found
	end
	if node[1] then
		grid.find(node[1], min, found)
	end
	if node[2] then
		grid.find(node[2], min, found)
	end
	return found
end

--- kv'deki `min` değerini doğrular; geçersizse varsayılan.
function grid.parse_min(value: any): Min
	if type(value) == "table" and type(value.rows) == "number" and type(value.cols) == "number" then
		return { rows = math.max(2, math.floor(value.rows)), cols = math.max(2, math.floor(value.cols)) }
	end
	return table.clone(DEFAULT_MIN)
end

return grid
