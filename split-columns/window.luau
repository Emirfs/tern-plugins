--!strict
-- Split columns: turns grids split row by row into columns.
--
-- Tern keeps splits as a binary tree. In an (A | B) / (C | D) layout the
-- horizontal divider cuts across both columns: dragging the right one up
-- pulls the left one with it. Once the same four panes are arranged as
-- (A / C) | (B / D), every column has its own horizontal divider. Wherever
-- the plugin finds a grid in a tab's tree whose rows all hold the same number
-- of panes (at least 2×2 by default, configurable), even when it is only part
-- of the tab, it turns the grid into columns by moving panes; programs keep
-- running. It runs automatically when it loads (for the open tab), on focus
-- change, and when a pane is opened or closed (can be turned off); it also
-- runs by hand from the command palette.

local grid = require("./grid")

local AUTO_KEY = "auto"
-- Smallest grid, { rows, cols }: smaller grids are not converted automatically.
local MIN_KEY = "min"

local function min_size(): grid.Min
	local ok, value = pcall(tern.kv.get, MIN_KEY)
	return grid.parse_min(if ok then value else nil)
end

-- Turns the row grids of at least `min` size in the tab into columns. If a move
-- fails, the layout is restored. Returns true if anything was converted.
local function to_columns(cx: WindowCx, tab: number, min: grid.Min): (boolean, string?)
	local layout = cx.session:layout(tab)
	if layout == nil or layout.zoomed then
		return false, nil
	end
	local grids = grid.find(layout.root, min)
	if #grids == 0 then
		return false, nil
	end
	local snap = cx.layout:snapshot()
	local keep = { focus = false }
	-- Move each row's pane below the pane in the row above: a row that empties
	-- closes, and each column becomes its own `down` chain. The moves stay among
	-- the grid's own leaves, so the ids of other grids remain valid.
	for _, g in grids do
		for i = 2, #g do
			for j, pane in g[i] do
				if not cx.layout:move(pane, g[i - 1][j], "down", keep) then
					cx.layout:restore(snap)
					return false, "could not move pane"
				end
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
		local _, err = to_columns(cx, tab, min_size())
		if err then
			cx:toast("error", "Split columns: " .. err)
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
		to_columns(cx, tab, min_size())
	end
end)
-- Layouts built before the plugin: in the tab switched to, and in the open tab on load.
tern.on("focus", function(ev, cx)
	if auto_enabled() then
		to_columns(cx, ev.tab, min_size())
	end
end)
tern.timer(0, function(cx)
	if cx and auto_enabled() then
		local tab = current_tab(cx)
		if tab then
			to_columns(cx, tab, min_size())
		end
	end
end)

tern.command({
	id = "columns",
	title = "Split grid into columns",
	icon = "columns",
	run = function(cx)
		local tab = current_tab(cx)
		if tab == nil then
			return
		end
		-- When run by hand, every grid counts (at least 2×2), not the configured minimum.
		local done, err = to_columns(cx, tab, grid.DEFAULT_MIN)
		if err then
			cx:toast("error", "Split columns: " .. err)
		elseif not done then
			cx:toast("info", "This tab is not a grid split row by row", "Every row must hold the same number of panes (at least 2).")
		end
	end,
})

tern.command({
	id = "toggle_auto",
	title = "Split columns: toggle automatic conversion",
	icon = "columns",
	run = function(cx)
		local enabled = not auto_enabled()
		tern.kv.set(AUTO_KEY, enabled)
		cx:toast("info", if enabled then "Automatic column layout on" else "Automatic column layout off")
	end,
})

local SIZES = { { 2, 2 }, { 2, 3 }, { 3, 2 }, { 3, 3 } }

tern.command({
	id = "min_size",
	title = "Split columns: smallest grid to convert automatically",
	icon = "columns",
	run = function(cx)
		local now = min_size()
		local items: { PickItem } = {}
		for _, s in SIZES do
			table.insert(items, {
				label = string.format("%d rows × %d columns", s[1], s[2]),
				detail = if s[1] == 2 and s[2] == 2 then "default" else nil,
				current = now.rows == s[1] and now.cols == s[2],
				rows = s[1],
				cols = s[2],
			})
		end
		cx:pick({ items = items, placeholder = "Smallest grid", icon = "columns", action = "select" }):next(function(item, _err, wcx)
			if item == nil then
				return
			end
			tern.kv.set(MIN_KEY, { rows = item.rows, cols = item.cols })
			if wcx then
				wcx:toast("info", "Smallest grid converted automatically: " .. item.label)
			end
		end)
	end,
})
