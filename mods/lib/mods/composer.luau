--!strict
-- omp sohbetlerinin alt satırı: yazma kutusu (`omp.editor` sütunu, Tern bunu
-- `.sf-dock` içinde çizer), altındaki model/hesap satırı (`omp.composer.bar`)
-- ve üstündeki durum satırı (`omp.hud`, "çalışıyor…" satırı `omp.hud.status`).
-- Soru (ask) kutusu da bir `omp.editor.*` sütunudur; ona `ask-style` bakar.

local schema = require("../schema")

local num = schema.num

local BOX = ".sf-col:is([data-role='omp.editor'], [data-role='omp.editor.bash'], [data-role='omp.editor.python'], [data-role='omp.editor.btw'])"

local DENSITY: { [string]: { pad_y: number, pad_x: number, min: number, gap: number } } = {
	compact = { pad_y = 6, pad_x = 10, min = 34, gap = 4 },
	normal = { pad_y = 11, pad_x = 14, min = 44, gap = 8 },
	spacious = { pad_y = 16, pad_x = 20, min = 56, gap = 12 },
}

local mod: schema.Mod = {
	id = "composer",
	defaults = { density = "compact", radius = 12, border = "subtle", background = "default", font = 14, status = "show" },
	fields = {
		{ key = "density", kind = "choice", options = { "compact", "normal", "spacious" }, style = "segmented" },
		{ key = "radius", kind = "number", min = 0, max = 28, step = 1, unit = "px" },
		{ key = "border", kind = "choice", options = { "none", "subtle", "accent" }, style = "segmented" },
		{ key = "background", kind = "choice", options = { "default", "solid", "clear", "tint" }, style = "segmented" },
		{ key = "font", kind = "number", min = 11, max = 18, step = 0.5, unit = "px" },
		{ key = "status", kind = "choice", options = { "show", "dim", "hide" }, style = "segmented" },
	},
	css = function(s, _env)
		local d = DENSITY[s.density] or DENSITY.normal
		local r: number = s.radius
		local f: number = s.font
		local css = {
			`{BOX} \{ padding: {num(d.pad_y)}px {num(d.pad_x)}px !important; min-height: {num(d.min)}px !important; gap: {num(d.gap)}px !important; border-radius: {num(r)}px !important; }`,
			`.sf-chat-reader {BOX} .sf-editor \{ font-size: {num(f)}px !important; line-height: {num(f + 8)}px !important; --sf-lh: {num(f + 8)}px; min-height: {num(f + 8)}px !important; }`,
		}
		if s.border == "none" then
			table.insert(css, `{BOX} \{ --composer-ring: transparent !important; }`)
			table.insert(css, `{BOX}::after \{ display: none !important; }`)
		elseif s.border == "accent" then
			table.insert(css, `{BOX} \{ --composer-ring: rgb(from var(--accent) r g b / 70%) !important; }`)
			table.insert(css, `{BOX}::after \{ background: rgb(from var(--accent) r g b / 55%) !important; }`)
		end
		if s.background == "solid" then
			table.insert(css, `{BOX} \{ background: var(--panel) !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }`)
		elseif s.background == "clear" then
			table.insert(css, `{BOX} \{ background: transparent !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; box-shadow: 0 0 0 1px var(--composer-ring) !important; }`)
		elseif s.background == "tint" then
			table.insert(css, `{BOX} \{ background: color-mix(in srgb, var(--accent) 12%, var(--raise, var(--panel))) !important; }`)
		end
		if s.status == "dim" then
			table.insert(css, ".sf-dock [data-role='omp.hud'] { opacity: 0.45; transition: opacity 0.15s ease; }")
			table.insert(css, ".sf-dock [data-role='omp.hud']:hover { opacity: 1; }")
		elseif s.status == "hide" then
			table.insert(css, ".sf-dock [data-role='omp.hud'] { display: none !important; }")
		end
		return table.concat(css, "\n")
	end,
}

return mod
