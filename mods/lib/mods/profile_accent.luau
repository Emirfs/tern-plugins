--!strict
-- An accent color per omp profile. Which pane runs which profile is found by the
-- window half from `tern inspect --json` (env.panes); only CSS is here:
-- on a tab, the pane's program icon carries `.tn-dk-c[data-pane=<id>]` and the tab
-- itself is found from it with `:has()`. Panes on the stage have no identity attribute;
-- the `.tn-head[title]` in their headers is matched with the pane title. A pane
-- whose header is not visible (a single-pane tab, `pane_headers` off) gets no color.

local schema = require("../schema")

-- A fixed order for profiles with no chosen color: the same name gets the same color everywhere.
local AUTO = { "violet", "orange", "teal", "pink", "green", "yellow", "blue", "red" }

--- A profile's color (CSS) or nil (no color): the chosen color, else `default` has none,
--- the others a fixed palette color derived from their name.
local function color_for(colors: { [string]: string }, profile: string): string?
	local chosen = colors[profile]
	if chosen == "none" then
		return nil
	end
	if chosen then
		return schema.color(chosen)
	end
	if profile == "default" then
		return nil
	end
	local h = 0
	for i = 1, #profile do
		h = (h * 31 + string.byte(profile, i)) % 2147483647
	end
	return schema.color(AUTO[h % #AUTO + 1])
end

local function css(s: schema.Settings, env: schema.Env): string?
	local colors: { [string]: string } = s.colors
	local edge = s.style ~= "tint"
	local tint = s.style ~= "edge"
	-- Focused panes go last: with two profiles in one tab, the tab takes the focused one's color.
	local ordered = table.clone(env.panes)
	table.sort(ordered, function(a, b)
		if a.focused ~= b.focused then
			return not a.focused
		end
		return a.pane < b.pane
	end)
	local out = {}
	for _, p in ordered do
		local c = color_for(colors, p.profile)
		if c then
			local id = string.format("%.0f", p.pane)
			if s.tabs then
				local tab = `:is(#tabbar .tt, #sidebar .nav-row):has(.tn-dk-c[data-pane="{id}"])`
				table.insert(out, `#tabbar .tn-dk-c[data-pane="{id}"] \{ color: {c} !important; }`)
				local shadow = if edge then `inset 0 -2px 0 {c}` else "none"
				local bg = if tint then `background-color: rgb(from {c} r g b / 16%) !important; ` else ""
				table.insert(out, `{tab} \{ {bg}box-shadow: {shadow} !important; }`)
			end
			if s.panes and p.title ~= "" then
				local pane = `.tn-stage .tn-pane:has(> .tn-head[title={schema.css_string(p.title)}])`
				if edge then
					table.insert(out, `{pane} > .tn-body \{ box-shadow: inset 0 0 0 1.5px {c} !important; }`)
					table.insert(out, `{pane} > .tn-head \{ box-shadow: inset 0 2px 0 {c} !important; }`)
				end
				if tint then
					table.insert(out, `{pane} > .tn-head \{ background-color: color-mix(in srgb, {c} 18%, var(--panel)) !important; }`)
					table.insert(out, `{pane} > .tn-head .tn-title \{ color: {c} !important; }`)
				end
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

local mod: schema.Mod = {
	id = "profile-accent",
	defaults = { style = "edge", tabs = true, panes = true, colors = {} },
	fields = {
		{ key = "style", kind = "choice", options = { "edge", "tint", "both" }, style = "segmented" },
		{ key = "tabs", kind = "bool" },
		{ key = "panes", kind = "bool" },
		{ key = "colors", kind = "colors" },
	},
	css = css,
}

return mod
