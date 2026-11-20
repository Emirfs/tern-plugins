--!strict
-- Appearance tab: global settings Tern's own settings don't have. Font, size,
-- theme, opacity, material, density and layout exist in Tern; here we only add
-- a theme-independent accent color and the UI corners. Presets turn on several
-- mods together.

local schema = require("./schema")

local appearance = {}

appearance.fields = {
	{ key = "accent", kind = "color", options = { "theme", "blue", "violet", "pink", "red", "orange", "yellow", "green", "teal", "gray" } },
	{ key = "corners", kind = "choice", options = { "theme", "square", "soft", "round" }, style = "segmented" },
} :: { schema.Field }

appearance.defaults = { accent = "theme", corners = "theme" } :: schema.Settings

-- `theme` is not a palette name; the color field is checked like a choice so validation accepts it too.
function appearance.normalize(raw: any): schema.Settings
	local src = if type(raw) == "table" then raw else {}
	local out: schema.Settings = schema.normalize(appearance.fields, appearance.defaults, src)
	if src.accent == "theme" then
		out.accent = "theme"
	end
	return out
end

function appearance.accept(key: string, v: any): any
	if key == "accent" and v == "theme" then
		return v
	end
	local f = schema.field(appearance.fields, key)
	return if f then schema.accept(f, v) else nil
end

local CORNERS: { [string]: { chip: number, ctl: number, card: number, panel: number, tab: number } } = {
	square = { chip = 2, ctl = 2, card = 3, panel = 4, tab = 3 },
	soft = { chip = 6, ctl = 8, card = 12, panel = 16, tab = 8 },
	round = { chip = 10, ctl = 14, card = 18, panel = 22, tab = 999 },
}

--- CSS for the appearance settings; nil when everything is left to the theme.
function appearance.css(s: schema.Settings): string?
	local css = {}
	local c = if s.accent ~= "theme" then schema.color(s.accent) else nil
	if c then
		-- Overrides the theme accent on `html` (even over inline styles); the light/dark variants derive from it.
		table.insert(
			css,
			`html \{ --accent: {c} !important; --accent-fill: color-mix(in oklab, {c}, black 12%) !important; --accent-ink: light-dark(color-mix(in oklab, {c}, black 30%), color-mix(in oklab, {c}, white 45%)) !important; accent-color: {c}; }`
		)
	end
	local r = CORNERS[s.corners]
	if r then
		table.insert(
			css,
			`html \{ --r-chip: {r.chip}px !important; --r-ctl: {r.ctl}px !important; --r-card: {r.card}px !important; --r-panel: {r.panel}px !important; }`
		)
		table.insert(css, `html #tabbar :is(.tt, .tb-pill, .tn-session-tab, .icon-btn) \{ border-radius: {r.tab}px !important; }`)
	end
	if #css == 0 then
		return nil
	end
	return table.concat(css, "\n")
end

-- Presets: applying one replaces the enabled mods with this list.
appearance.PRESETS = {
	minimal = { "compact-tabs", "tab-style", "pane-shape" },
	cozy = { "tab-style", "pane-shape", "composer", "busy-animation" },
	presenter = { "privacy-blur", "focus-mode" },
} :: { [string]: { string } }
appearance.PRESET_ORDER = { "minimal", "cozy", "presenter" }

return appearance
