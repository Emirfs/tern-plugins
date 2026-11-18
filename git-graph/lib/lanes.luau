--!strict
-- Lane layout for a commit list in `git log` order (children before parents): one text row per commit,
-- like `git log --graph` squeezed to a single line. Every lane keeps its color from where it opened to
-- where it ends, so a branch reads as one colored line even after its neighbours end.
--
-- A row is two cells per lane: the lane's glyph and the gap after it. Horizontal links (a lane joining
-- the commit, or the commit opening a lane for a second parent) run through the gaps and cross
-- straight lanes as `┼`.

local Lanes = {}

Lanes.COLORS = 6

export type Input = { hash: string, parents: { string } }
-- One drawn cell: its glyph and the lane color index (1..COLORS) it belongs to; 0 is blank.
export type Cell = { ch: string, color: number }
export type Row = {
	-- Lane the commit sits on (1-based).
	col: number,
	color: number,
	cells: { Cell },
	-- Where the commit's node connects: its lane comes from above (a child), goes on below (a parent),
	-- and a horizontal link leaves it to the left or right. Drawn graphics need these; glyphs imply them.
	top: boolean,
	bottom: boolean,
	left: boolean,
	right: boolean,
}

type Lane = { hash: string, color: number }

local function blank(): Cell
	return { ch = " ", color = 0 }
end

local function first_free(lanes: { Lane | false }, taken: { [number]: boolean }): number
	for i, lane in lanes do
		if lane == false and not taken[i] then
			return i
		end
	end
	return #lanes + 1
end

-- Draws a horizontal link from lane `from` to lane `to` (exclusive of `from`), ending in `cap`.
local function link(cells: { Cell }, from: number, to: number, cap: string, color: number)
	local a, b = 2 * from - 1, 2 * to - 1
	local step = if b > a then 1 else -1
	for i = a + step, b - step, step do
		local cell = cells[i]
		if cell.ch == "│" then
			cells[i] = { ch = "┼", color = cell.color }
		elseif cell.ch == " " or cell.ch == "─" then
			cells[i] = { ch = "─", color = color }
		end
	end
	cells[b] = { ch = cap, color = color }
end

--- Lays out `commits`; `head` marks the checked-out commit.
function Lanes.layout(commits: { Input }, head: string?): { Row }
	local lanes: { Lane | false } = {}
	local next_color = 0
	local function color(): number
		next_color = next_color % Lanes.COLORS + 1
		return next_color
	end

	local rows: { Row } = {}
	for _, c in commits do
		-- Every lane waiting for this commit: the first one carries it, the others join it here.
		local col: number? = nil
		local joining: { number } = {}
		for i, lane in lanes do
			if lane ~= false and (lane :: Lane).hash == c.hash then
				if col == nil then
					col = i
				else
					table.insert(joining, i)
				end
			end
		end
		local here: number = col or first_free(lanes, {})
		if col == nil then
			lanes[here] = { hash = c.hash, color = color() }
		end
		local own = lanes[here] :: Lane

		-- Second and later parents: an existing lane gets a link, a new one opens beside.
		local taken: { [number]: boolean } = { [here] = true }
		for _, j in joining do
			taken[j] = true
		end
		local opened: { { at: number, existing: boolean } } = {}
		for p = 2, #c.parents do
			local parent = c.parents[p]
			local at: number? = nil
			for i, lane in lanes do
				if lane ~= false and (lane :: Lane).hash == parent and not taken[i] then
					at = i
					break
				end
			end
			if at then
				table.insert(opened, { at = at, existing = true })
				taken[at] = true
			else
				local slot = first_free(lanes, taken)
				lanes[slot] = { hash = parent, color = color() }
				taken[slot] = true
				table.insert(opened, { at = slot, existing = false })
			end
		end

		local width = #lanes
		local cells: { Cell } = table.create(2 * width - 1)
		for i = 1, 2 * width - 1 do
			cells[i] = blank()
		end
		for i, lane in lanes do
			if lane ~= false and i ~= here then
				local new = false
				for _, o in opened do
					if o.at == i and not o.existing then
						new = true
					end
				end
				if not new then
					cells[2 * i - 1] = { ch = "│", color = (lane :: Lane).color }
				end
			end
		end
		local glyph = if c.hash == head then "◉" elseif #c.parents > 1 then "○" else "●"
		cells[2 * here - 1] = { ch = glyph, color = own.color }

		for _, j in joining do
			local lane = lanes[j] :: Lane
			link(cells, here, j, if j > here then "╯" else "╰", lane.color)
		end
		for _, o in opened do
			local lane = lanes[o.at] :: Lane
			local cap = if o.existing then (if o.at > here then "┤" else "├") else (if o.at > here then "╮" else "╭")
			link(cells, here, o.at, cap, lane.color)
		end

		-- Trailing blanks cost width in every row; trim them.
		while #cells > 0 and cells[#cells].ch == " " do
			table.remove(cells)
		end
		local left, right = false, false
		for _, j in joining do
			left, right = left or j < here, right or j > here
		end
		for _, o in opened do
			left, right = left or o.at < here, right or o.at > here
		end
		table.insert(rows, {
			col = here, color = own.color, cells = cells,
			top = col ~= nil, bottom = #c.parents > 0, left = left, right = right,
		})

		-- Advance: the commit's lane follows its first parent; joined lanes end here.
		for _, j in joining do
			lanes[j] = false
		end
		if c.parents[1] then
			lanes[here] = { hash = c.parents[1], color = own.color }
		else
			lanes[here] = false
		end
		while #lanes > 0 and lanes[#lanes] == false do
			table.remove(lanes)
		end
	end
	return rows
end

--- Groups a row's cells into runs of one color: `{text, color}` pairs, ready to become styled spans.
function Lanes.runs(row: Row): { { any } }
	local out: { { any } } = {}
	for _, cell in row.cells do
		local last = out[#out]
		if last and last[2] == cell.color then
			last[1] = (last[1] :: string) .. cell.ch
		else
			local run: { any } = { cell.ch, cell.color }
			table.insert(out, run)
		end
	end
	return out
end

return Lanes
