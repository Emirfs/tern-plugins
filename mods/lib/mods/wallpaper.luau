--!strict
-- Pencerenin arkasında duvar kağıdı: hareketli degrade ya da bir görsel.
-- Resim `body`'ye konur, `main#panel` saydamlaşır (tern-backdrop'un yöntemi;
-- github.com/avcton/tern-backdrop, MIT). Görselin baytlarını pencere yarısı
-- okuyup `data:` URL'si yapar (env.wallpaper_url): bir stil sayfasının `url()`'si
-- eklenti klasörü dışını gösteremez. Tern CSS arka planında hareketli GIF/WebP'nin
-- yalnız ilk karesini çizer; onları host yarısı ffmpeg ile tek bir kare dizisine
-- (sprite sheet) çevirir, kareler burada @keyframes ile oynar (env.wallpaper_anim).

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

-- Karartma, temaya uyan bir örtüyle: koyu temada koyu, açıkta açık.
local SCRIM = "html { --mods-scrim: light-dark(#f4f4f6, #101014); }"

local function scrim(dim: number): string
	local a = num(dim / 100)
	return `linear-gradient(rgb(from var(--mods-scrim) r g b / {a}), rgb(from var(--mods-scrim) r g b / {a}))`
end

-- Sprite sheet'in kareleri: her kare pencereyi "cover" gibi kaplar, karenin
-- ortası pencerenin ortasına gelir; kare değişimi step-end ile.
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
			-- Görsel seçilmedi ya da okunamadı: Tern'in kendi arka planı kalır.
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
			-- Sekme ve widget çubuğu, arkadaki resim karışık olsa da okunsun diye hafif bir örtü.
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
