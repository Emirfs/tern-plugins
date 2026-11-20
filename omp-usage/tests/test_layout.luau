--!strict
local check = require("./check")
local layout = require("../lib/layout")

-- Two providers: one with a single account, one with two; two windows.
local SHAPE = { 1, 2 }

do
	local wide = layout.table_for(SHAPE, 2, 1, 200, 40)
	check.eq(wide.bars and wide.resets and not wide.narrow and not wide.collapse, true, "wide pane shows everything")
	check.eq(wide.table_lines, 1 + 1 + 3, "header + single account + total and two accounts")

	local mid = layout.table_for(SHAPE, 2, 1, 50, 40)
	check.eq(mid.bars, false, "bars go first")
	check.eq(mid.resets, true, "resets stay while they fit")

	local narrow = layout.table_for(SHAPE, 2, 1, 31, 40)
	check.eq(narrow.resets, false, "resets go next")
	check.eq(narrow.narrow, true, "e-mails go when even percentages are tight")
	check.eq(narrow.tiny, false, "still a table at 31 columns")

	local tiny = layout.table_for(SHAPE, 2, 1, 29, 40)
	check.eq(tiny.tiny and tiny.collapse, true, "tiny pane lists totals")

	local short = layout.table_for(SHAPE, 2, 1, 200, 8)
	check.eq(short.collapse, true, "short pane collapses multi-account providers")
	check.eq(short.table_lines, 1 + #SHAPE, "one line per provider when collapsed")
end

do
	check.eq(layout.roomy_lines(SHAPE, 2, 1), (1 + 2) + (1 + 2 * 3) + 1 + 1, "stacked line count")
	local fits, wide = layout.roomy(SHAPE, 2, 1, 80, 40)
	check.eq(fits and wide, true, "stacked view fits a large pane, in words")
	fits = layout.roomy(SHAPE, 2, 1, 43, 40)
	check.eq(fits, false, "too narrow for the stacked view")
	fits = layout.roomy(SHAPE, 2, 1, 80, 15)
	check.eq(fits, false, "too short for the stacked view")
end
