--!strict
-- View choice by pane size. Pure: works only from column/row counts;
-- the view never asks for scrolling at any size.

local layout = {}

-- Stacked view: at least this many columns; above the wider threshold percentages and times are written out in words.
layout.ROOMY_MIN_COLS = 44
layout.ROOMY_WIDE_COLS = 64
-- Gap between provider groups in the stacked view, in lines.
layout.GROUP_GAP_LINES = 1

-- Block rows are ~40% taller than pane cells; region margins are ~2 cells.
layout.ROW_CELLS = 1.4
layout.CHROME_CELLS = 2
-- Column widths, in cells: account label, remaining+reset per window,
-- bar, remaining percentage only.
layout.ACCOUNT_COLS = 18
layout.WINDOW_COLS = 15
layout.BAR_COLS = 15
layout.PCT_COLS = 7
-- Below this a list replaces the table: the label is truncated, the percentages stay on the right.
layout.TINY_COLS = 30
-- The key hint in the status line is not shown in panes narrower than this.
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

-- Account counts per provider: the view looks only at these.
export type Shape = { number }

--- What fits for the table/list: in a narrow pane the bars go first, then the reset
--- columns, in the narrowest the e-mails drop and it switches to the list view; in a short or
--- very narrow pane providers with several accounts collapse to a single total row.
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

--- The line count of the stacked view (in table-row units).
function layout.roomy_lines(shape: Shape, windows: number, status_count: number): number
	local n = 0
	for _, k in shape do
		n += if k == 1 then 1 + windows else 1 + k * (1 + windows)
	end
	return n + (#shape - 1) * layout.GROUP_GAP_LINES + status_count
end

--- Whether the stacked view fits; if so, whether in the wide (worded) form.
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
