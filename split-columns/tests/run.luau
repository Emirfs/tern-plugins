--!strict
-- Depo kökünden: `lune run split-columns/tests/run.luau`.
local grid = require("../grid")

local count = 0
local function eq(got: any, want: any, what: string)
	count += 1
	local a, b = if type(got) == "table" then table.concat(got, ",") else tostring(got), if type(want) == "table" then table.concat(want, ",") else tostring(want)
	if a ~= b then
		error(`{what}: got {a}, want {b}`, 2)
	end
end

local function leaf(id: number): any
	return { pane = id }
end
local function split(dir: string, a: any, b: any): any
	return { split = dir, a, b }
end
local function row(...: number): any
	local ids = { ... }
	local node = leaf(ids[#ids])
	for i = #ids - 1, 1, -1 do
		node = split("right", leaf(ids[i]), node)
	end
	return node
end
local function rows(...: any): any
	local list = { ... }
	local node = list[#list]
	for i = #list - 1, 1, -1 do
		node = split("down", list[i], node)
	end
	return node
end

local MIN = grid.DEFAULT_MIN

-- 2×2 satır ızgarası bulunur, satır satır
local g = grid.rows_grid(rows(row(1, 2), row(3, 4)), MIN) :: { { number } }
eq(#g, 2, "2x2 rows")
eq(g[1], { 1, 2 }, "first row")
eq(g[2], { 3, 4 }, "second row")

-- Zaten sütun düzeni, tek satır ya da düzensiz satırlar ızgara değil
eq(grid.rows_grid(split("right", split("down", leaf(1), leaf(3)), split("down", leaf(2), leaf(4))), MIN), nil, "columns already")
eq(grid.rows_grid(rows(row(1, 2), row(3, 4, 5)), MIN), nil, "ragged rows")
eq(grid.rows_grid(rows(row(1, 2), leaf(3)), MIN), nil, "a full-width row")

-- En küçük boyut
local three_by_two = rows(row(1, 2), row(3, 4), row(5, 6))
eq(grid.rows_grid(rows(row(1, 2), row(3, 4)), { rows = 3, cols = 2 }), nil, "2x2 below a 3-row minimum")
eq(#(grid.rows_grid(three_by_two, { rows = 3, cols = 2 }) :: any), 3, "3x2 meets a 3-row minimum")
eq(grid.rows_grid(three_by_two, { rows = 2, cols = 3 }), nil, "2 columns below a 3-column minimum")

-- Sekmenin bir parçası: tam boy pane'in yanındaki ızgara
local tab = split("right", leaf(9), rows(row(1, 2), row(3, 4)))
eq(#grid.find(tab, MIN), 1, "grid beside a full-height pane")
eq(#grid.find(tab, { rows = 3, cols = 3 }), 0, "too small for the setting")

-- kv değeri doğrulanır
local m = grid.parse_min({ rows = 3.7, cols = 1 })
eq(m.rows, 3, "rows floored")
eq(m.cols, 2, "cols at least 2")
eq(grid.parse_min("junk").rows, 2, "invalid value gives the default")

print(`all {count} checks passed`)
