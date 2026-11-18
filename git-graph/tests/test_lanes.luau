--!strict
local check = require("./check")
local lanes = require("../lib/lanes")

local function text(row: lanes.Row): string
	local out = {}
	for _, cell in row.cells do
		table.insert(out, cell.ch)
	end
	return table.concat(out)
end

local function c(hash: string, ...: string): lanes.Input
	return { hash = hash, parents = { ... } }
end

-- Linear history stays on one lane; HEAD gets its own glyph
do
	local rows = lanes.layout({ c("c3", "c2"), c("c2", "c1"), c("c1") }, "c3")
	check.eq(text(rows[1]), "◉", "head glyph")
	check.eq(text(rows[2]), "●", "plain commit")
	check.eq(text(rows[3]), "●", "root")
	check.eq(rows[1].color, rows[3].color, "one lane keeps one color")
end

-- A merge opens a lane for its second parent; the lanes join again at the fork point
do
	local rows = lanes.layout({ c("m", "a2", "b1"), c("b1", "a1"), c("a2", "a1"), c("a1") }, nil)
	check.eq(text(rows[1]), "○─╮", "merge opens the second parent's lane")
	check.eq(text(rows[2]), "│ ●", "branch commit on lane 2")
	check.eq(text(rows[3]), "● │", "main commit on lane 1")
	check.eq(text(rows[4]), "●─╯", "lane 2 joins at the fork point")
	check.truthy(rows[2].color ~= rows[3].color, "branch and main lanes differ in color")
	check.eq(rows[4].cells[3].color, rows[2].color, "the join is drawn in the joining lane's color")
end

-- Two tips without a merge: the second tip opens a lane, both meet at their common parent
do
	local rows = lanes.layout({ c("f2", "f1"), c("m2", "m1"), c("f1", "m1"), c("m1") }, "m2")
	check.eq(text(rows[1]), "●", "first tip")
	check.eq(text(rows[2]), "│ ◉", "second tip beside the first")
	check.eq(text(rows[3]), "● │", "first branch continues")
	check.eq(text(rows[4]), "●─╯", "both meet at the common parent")
end

-- A merge whose second parent already has a lane links to it instead of opening one; crossings show ┼
do
	local rows = lanes.layout({
		c("x", "p"), -- lane 1
		c("y", "q"), -- lane 2
		c("m", "q2", "p"), -- lane 3, second parent p sits on lane 1
		c("p"), c("q", "q2"), c("q2"),
	}, nil)
	check.eq(text(rows[3]), "├─┼─○", "link to an existing lane crosses lane 2")
end

-- Lanes freed on the right are trimmed so rows stay narrow
do
	local rows = lanes.layout({ c("m", "a", "b"), c("b", "a"), c("a", "z"), c("z") }, nil)
	check.eq(text(rows[4]), "●", "no trailing blanks after lanes end")
end

-- runs() groups cells by color for styled spans
do
	local rows = lanes.layout({ c("m", "a", "b"), c("b", "a"), c("a") }, nil)
	local runs = lanes.runs(rows[1])
	check.eq(#runs, 2, "node, then the opened lane's link")
	check.eq(runs[2][1], "─╮", "link and cap share a run")
end
