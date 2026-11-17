--!strict
-- İnce sekme çubuğu. Tern çubuğun yüksekliğini `--tn-bar` değişkeninden alır
-- (her düzen kendi değerini `html.lay-*` üzerinde verir); paneller de ona göre
-- yukarı kayar. Yalnız yatay sekmeler: dikey sekmelerde (`tabs-v`) çubuk yoktur.

local schema = require("../schema")

local num = schema.num

local mod: schema.Mod = {
	id = "compact-tabs",
	defaults = { height = 30, font = 11.5, blocks = false },
	fields = {
		{ key = "height", kind = "number", min = 24, max = 38, step = 1, unit = "px" },
		{ key = "font", kind = "number", min = 10, max = 13, step = 0.5, unit = "px" },
		{ key = "blocks", kind = "bool" },
	},
	css = function(s, _env)
		local h: number = s.height
		local tab = math.max(16, h - 10)
		local btn = math.max(16, h - 12)
		local css = {
			`html.tabs-h \{ --tn-bar: max(20px, calc({num(h)}px * var(--tn-zoom, 1))) !important; }`,
			`html.tabs-h #tabbar \{ --tb-in-h: {num(h - 6)}px !important; --tb-btn: {num(btn)}px !important; }`,
			`html.tabs-h #tabbar .tt \{ height: {num(tab)}px !important; padding: 0 8px !important; gap: 5px !important; font-size: {num(s.font)}px !important; }`,
			`html.tabs-h #tabbar :is(.tn-session-tab, .tn-host-tab) \{ height: {num(tab)}px !important; font-size: {num(s.font)}px !important; }`,
			`html.tabs-h #tabbar :is(.tb-in > .icon-btn, .tb-tools .icon-btn, .tn-peers) \{ height: {num(btn)}px !important; width: {num(btn)}px !important; margin-top: 0 !important; }`,
			`html.tabs-h #tabbar .tb-pill \{ height: {num(tab)}px !important; }`,
		}
		if not s.blocks then
			-- Yeni blok kısayolları (Terminal, Browser, Note…): ince çubukta yer kaplamasın.
			table.insert(css, "html.tabs-h #tabbar .tb-blocks { display: none !important; }")
		end
		return table.concat(css, "\n")
	end,
}

return mod
