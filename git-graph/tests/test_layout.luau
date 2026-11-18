--!strict
local check = require("./check")
local layout = require("../lib/layout")

-- Narrow below the threshold, wide at and above it
do
	local l = layout.default()
	check.eq(layout.mode(l, l.threshold - 1), "narrow", "one column under the threshold is narrow")
	check.eq(layout.mode(l, l.threshold), "wide", "the threshold itself is wide")
	check.eq(layout.visible(l, 60).author, false, "author hidden when narrow by default")
	check.eq(layout.visible(l, 200).author, true, "author shown when wide by default")
end

-- Toggling one part of one mode leaves the other mode alone
do
	local l = layout.default()
	check.eq(layout.toggle(l, "narrow", "hash"), true, "known part toggles")
	check.eq(l.narrow.hash, true, "narrow hash now on")
	check.eq(l.wide.hash, true, "wide hash unchanged")
	check.eq(layout.toggle(l, "narrow", "nope"), false, "unknown part refused")
	check.eq(layout.toggle(l, "tall", "hash"), false, "unknown mode refused")
end

-- Stored layouts: clamped, unknown keys dropped, missing parts from the default
do
	local l = layout.sanitize({ threshold = 5, narrow = { graph = false, bogus = true }, wide = "x" })
	check.eq(l.threshold, layout.MIN, "threshold clamped")
	check.eq(l.narrow.graph, false, "stored part kept")
	check.eq(l.narrow.bogus, nil, "unknown part dropped")
	check.eq(l.narrow.detail, true, "missing part from the default")
	check.eq(l.wide.toolbar, true, "a malformed mode falls back to the default")
	check.eq(layout.sanitize(nil).threshold, layout.default().threshold, "nothing stored: default")
end

-- A v1 layout (narrow panes hid the branch list) gets the strip; a v2 choice to hide it is kept
do
	check.eq(layout.sanitize({ narrow = { sidebar = false } }).narrow.sidebar, true, "v1 layout migrates to the strip")
	check.eq(layout.sanitize({ v = layout.VERSION, narrow = { sidebar = false } }).narrow.sidebar, false, "v2 choice kept")
	check.eq(layout.sanitize({ narrow = { sidebar = false } }).v, layout.VERSION, "migrated layout carries the version")
end
