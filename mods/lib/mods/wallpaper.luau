--!strict
-- A wallpaper behind the window: an animated gradient or an image.
-- The picture goes on `body` and `main#panel` turns transparent (tern-backdrop's method;
-- github.com/avcton/tern-backdrop, MIT). The window half reads the image's bytes
-- and makes a `data:` URL (env.wallpaper_url): a stylesheet's `url()`
-- can't point outside the plugin folder. Tern draws only the first frame of an animated
-- GIF/WebP in a CSS background; the host half converts those with ffmpeg into one frame
-- sheet (sprite sheet) and the frames play here with @keyframes (env.wallpaper_anim).

local schema = require("../schema")

local num = schema.num

local PRESETS: { [string]: { string } } = {
	aurora = { "#12c2e9", "#c471ed", "#f64f59", "#12c2e9" },
	sunset = { "#ff7e5f", "#feb47b", "#ff5f6d", "#ffc371" },
	ocean = { "#1e3c72", "#2193b0", "#6dd5ed", "#2a5298" },
	forest = { "#134e5e", "#71b280", "#2c7744", "#0b3d2e" },
	candy = { "#fc5c7d", "#6a82fb", "#d66d75", "#e29587" },
	mono = { "#232526", "#414345", "#1c1c1c", "#3a3a3a" },
}
local PRESET_ORDER = { "aurora", "sunset", "ocean", "forest", "candy", "mono" }

-- Dimming with a veil that matches the theme: dark on a dark theme, light on a light one.
local SCRIM = "html { --mods-scrim: light-dark(#f4f4f6, #101014); }"

local function scrim(dim: number): string
	local a = num(dim / 100)
	return `linear-gradient(rgb(from var(--mods-scrim) r g b / {a}), rgb(from var(--mods-scrim) r g b / {a}))`
end

-- The sprite sheet's frames: each frame covers the window like "cover", and the frame's
-- middle lands on the window's middle; frames switch with step-end.
local function anim_css(a: schema.Anim, dim: number): string
	local w = `max(100vw, {num(a.ratio)} * 100vh)`
	local h = `max(100vh, 100vw / {num(a.ratio)})`
	local keys = {}
	for i = 0, a.frames - 1 do
		local col = i % a.cols
		local row = i // a.cols
		local pct = num(i / a.frames * 100)
		table.insert(
			keys,
			`  {pct}% \{ background-position: 0 0, calc(50vw - {num(col + 0.5)} * {w}) calc(50vh - {num(row + 0.5)} * {h}); }`
		)
	end
	return table.concat({
		"body {",
		`  background-image: {scrim(dim)}, url({schema.css_string(a.url)}) !important;`,
		`  background-size: 100% 100%, calc({a.cols} * {w}) calc({a.rows} * {h}) !important;`,
		"  background-repeat: no-repeat, no-repeat !important;",
		`  animation: mods-wp-frames {num(a.frames / a.fps)}s step-end infinite !important;`,
		"}",
		"@keyframes mods-wp-frames {",
		table.concat(keys, "\n"),
		"}",
	}, "\n")
end

local mod: schema.Mod = {
	id = "wallpaper",
	defaults = {
		source = "gradient",
		preset = "aurora",
		speed = 30,
		image = "",
		fit = "cover",
		dim = 35,
		panes = "glass",
		bars = true,
	},
	fields = {
		{ key = "source", kind = "choice", options = { "gradient", "image" }, style = "segmented" },
		{ key = "preset", kind = "choice", options = PRESET_ORDER, style = "menu" },
		{ key = "speed", kind = "number", min = 4, max = 120, step = 2, unit = "s" },
		{ key = "image", kind = "path" },
		{ key = "fit", kind = "choice", options = { "cover", "contain", "tile" }, style = "segmented" },
		{ key = "dim", kind = "number", min = 0, max = 90, step = 5, unit = "%" },
		{ key = "panes", kind = "choice", options = { "native", "glass", "clear" }, style = "segmented" },
		{ key = "bars", kind = "bool" },
	},
	css = function(s, env)
		local dim: number = s.dim
		local bg: string? = nil
		if s.source == "gradient" then
			local c = PRESETS[s.preset] or PRESETS.aurora
			local stops = table.concat(c, ", ") .. ", " .. c[1]
			bg = table.concat({
				"body {",
				"  background-color: var(--mods-scrim) !important;",
				`  background-image: {scrim(dim)}, linear-gradient(120deg, {stops}) !important;`,
				"  background-size: 100% 100%, 400% 400% !important;",
				"  background-repeat: no-repeat, no-repeat !important;",
				`  animation: mods-wp-drift {num(s.speed)}s ease-in-out infinite alternate !important;`,
				"}",
				"@keyframes mods-wp-drift {",
				"  0% { background-position: 0 0, 0% 50%; }",
				"  100% { background-position: 0 0, 100% 50%; }",
				"}",
			}, "\n")
		elseif env.wallpaper_anim then
			bg = anim_css(env.wallpaper_anim, dim)
		elseif env.wallpaper_url then
			local size, rep = "cover", "no-repeat"
			if s.fit == "contain" then
				size = "contain"
			elseif s.fit == "tile" then
				size, rep = "auto", "repeat"
			end
			bg = table.concat({
				"body {",
				"  background-color: var(--mods-scrim) !important;",
				`  background-image: {scrim(dim)}, url({schema.css_string(env.wallpaper_url)}) !important;`,
				`  background-size: 100% 100%, {size} !important;`,
				`  background-repeat: no-repeat, {rep} !important;`,
				"  background-position: center, center !important;",
				"}",
			}, "\n")
		end
		if bg == nil then
			-- No image chosen or it couldn't be read: Tern's own background stays.
			return nil
		end
		local css = { SCRIM, "main#panel { background: transparent !important; }", bg }
		if s.panes == "glass" then
			table.insert(
				css,
				".tn-stage .tn-pane > :is(.tn-body, .tn-head) { background-color: rgb(from var(--panel) r g b / 78%) !important; -webkit-backdrop-filter: blur(18px) saturate(140%); backdrop-filter: blur(18px) saturate(140%); }"
			)
		elseif s.panes == "clear" then
			table.insert(css, ".tn-stage .tn-pane > :is(.tn-body, .tn-head) { background-color: rgb(from var(--panel) r g b / 50%) !important; }")
		end
		if s.bars then
			-- A light veil over the tab and widget bars so they stay readable even over a busy image.
			table.insert(
				css,
				"html #tabbar { background-image: linear-gradient(rgb(from var(--mods-scrim) r g b / 62%) 55%, rgb(from var(--mods-scrim) r g b / 0)) !important; }"
			)
			table.insert(
				css,
				"html #widgetbar { background-image: linear-gradient(rgb(from var(--mods-scrim) r g b / 0), rgb(from var(--mods-scrim) r g b / 62%) 45%) !important; }"
			)
		end
		return table.concat(css, "\n")
	end,
}

return mod
