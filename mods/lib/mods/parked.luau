--!strict
-- Park edilmiş pane'lerin destesi (`.pk-pile`, sahnenin alt kenarında yelpaze
-- gibi kartlar). Destenin yeri ve boyu Tern'in kendi ayarları (`park_pile`,
-- `park_pile_size`, kart sürüklenerek); burada kartların görünüşü.

local schema = require("../schema")

local num = schema.num

local mod: schema.Mod = {
	id = "parked",
	defaults = { look = "compact", fade = 60, accent = true },
	fields = {
		{ key = "look", kind = "choice", options = { "cards", "compact", "preview" }, style = "segmented" },
		{ key = "fade", kind = "number", min = 10, max = 100, step = 5, unit = "%" },
		{ key = "accent", kind = "bool" },
	},
	css = function(s, _env)
		local css = {
			`.pk-pile:not(:hover, .sliding, .sizing, .drop) .pk-fan \{ opacity: {num(s.fade / 100)}; transition: opacity 0.2s ease; }`,
		}
		if s.look == "compact" then
			-- Önizlemesiz kart: yalnız simge ve başlık; kart boyu yarıya iner.
			table.insert(css, ".pk-card .pk-rise { top: 52px !important; height: 46px !important; }")
			table.insert(css, ".pk-card :is(.pk-face, .pk-bb) { display: none !important; }")
		elseif s.look == "preview" then
			-- Büyük önizleme: üzerine gelinen kart yükselir ve büyür.
			table.insert(css, ".pk-card:hover .pk-rise { transform: translateY(-18px) scale(1.6) !important; transform-origin: 50% 100%; z-index: 5; }")
		end
		if s.accent then
			table.insert(css, ".pk-card .pk-c { box-shadow: inset 0 2px 0 var(--accent), 0 0 0 1px var(--pk-rim), 0 6px 16px -10px var(--pk-drop) !important; }")
		end
		return table.concat(css, "\n")
	end,
}

return mod
