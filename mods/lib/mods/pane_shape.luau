--!strict
-- Pane'ler arası boşluk ve köşe yuvarlaklığı. Tern ikisini düzenin
-- değişkenlerinden alır: Tiles `--tn-tile-gap`/`--tn-tile-r`, Rail/Float ve
-- "islands" yoğunluğu `--tn-island-gap`/`--tn-island-r`. Boşluk her pane'in
-- iç dolgusu olduğundan iki pane arası onun iki katıdır; burada yarısı yazılır.

local schema = require("../schema")

local num = schema.num

local mod: schema.Mod = {
	id = "pane-shape",
	defaults = { gap = 6, radius = 11, outline = true },
	fields = {
		{ key = "gap", kind = "number", min = 0, max = 24, step = 1, unit = "px" },
		{ key = "radius", kind = "number", min = 0, max = 28, step = 1, unit = "px" },
		{ key = "outline", kind = "bool" },
	},
	css = function(s, _env)
		local half = s.gap / 2
		local r: number = s.radius
		local css = {
			`html \{ --tn-tile-gap: calc({num(half)}px * var(--tn-zoom, 1)) !important; --tn-island-gap: calc({num(half)}px * var(--tn-zoom, 1)) !important; --tn-tile-r: calc({num(r)}px * var(--tn-zoom, 1)) !important; --tn-island-r: calc({num(r)}px * var(--tn-zoom, 1)) !important; }`,
			-- Başlıklı pane'in başlığı yarıçapı sabit 11px ile çizer.
			`html .tn-stage .tn-pane.headed > .tn-head \{ border-radius: {num(r)}px {num(r)}px 0 0 !important; }`,
			`html .tn-stage .tn-pane.headed > .tn-body \{ border-radius: 0 0 {num(r)}px {num(r)}px !important; }`,
			`html .tn-stage .tn-pane:not(.headed) > .tn-body \{ border-radius: {num(r)}px !important; }`,
		}
		if not s.outline then
			table.insert(css, "html .tn-stage .tn-pane::before { box-shadow: none !important; }")
		end
		return table.concat(css, "\n")
	end,
}

return mod
