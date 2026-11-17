--!strict
-- Görünüm sekmesi: Tern'in kendi ayarlarında olmayan genel ayarlar. Yazı tipi,
-- boyut, tema, saydamlık, malzeme, yoğunluk, düzen Tern'de var; burada yalnız
-- temadan bağımsız vurgu rengi ve arayüz köşeleri. Hazır setler birkaç modu
-- birlikte açar.

local schema = require("./schema")

local appearance = {}

appearance.fields = {
	{ key = "accent", kind = "color", options = { "theme", "blue", "violet", "pink", "red", "orange", "yellow", "green", "teal", "gray" } },
	{ key = "corners", kind = "choice", options = { "theme", "square", "soft", "round" }, style = "segmented" },
} :: { schema.Field }

appearance.defaults = { accent = "theme", corners = "theme" } :: schema.Settings

-- `theme` palet adı değil; doğrulama onu da kabul etsin diye renk alanı seçenek gibi denetlenir.
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

--- Görünüm ayarlarının CSS'i; hepsi temadaysa nil.
function appearance.css(s: schema.Settings): string?
	local css = {}
	local c = if s.accent ~= "theme" then schema.color(s.accent) else nil
	if c then
		-- Tema vurgusunu `html` üzerinde (satır içi stil de olsa) ezer; açık/koyu karşılıkları ondan türer.
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

-- Hazır setler: uygulanınca açık modlar bu listeyle değişir.
appearance.PRESETS = {
	minimal = { "compact-tabs", "tab-style", "pane-shape" },
	cozy = { "tab-style", "pane-shape", "composer", "busy-animation" },
	presenter = { "privacy-blur", "focus-mode" },
} :: { [string]: { string } }
appearance.PRESET_ORDER = { "minimal", "cozy", "presenter" }

return appearance
