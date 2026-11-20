--!strict
-- Finds grids split row by row in a tab's tree. Pure: it only looks at the
-- layout tree (`TabTree`), so it is testable.

local grid = {}

-- Smallest grid to convert: number of rows × panes per row.
export type Min = { rows: number, cols: number }

local DEFAULT_MIN: Min = { rows = 2, cols = 2 }
grid.DEFAULT_MIN = DEFAULT_MIN

-- Flattens nested splits in direction `dir` in order: (A | (B | C)) → A, B, C.
local function chain(t: TabTree, dir: string, out: { TabTree })
	if t.pane == nil and t.split == dir and t[1] and t[2] then
		chain(t[1], dir, out)
		chain(t[2], dir, out)
	else
		table.insert(out, t)
	end
end

--- If the node is split into rows (`down`), has at least `min.rows` rows, and
--- every row consists of the same number of (at least `min.cols`) side-by-side
--- panes, returns the pane ids row by row; otherwise nil.
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

--- Every row grid in the tree; it does not descend into a grid.
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

--- Validates the `min` value from kv; falls back to the default if invalid.
function grid.parse_min(value: any): Min
	if type(value) == "table" and type(value.rows) == "number" and type(value.cols) == "number" then
		return { rows = math.max(2, math.floor(value.rows)), cols = math.max(2, math.floor(value.cols)) }
	end
	return table.clone(DEFAULT_MIN)
end

return grid
