--!strict
-- Pencere yarısı: kullanım bloğunu yanda açan (ya da bu pencerede zaten
-- açıksa ona odaklanan) palet komutu ve kısayol, bir de dil seçimi.

local i18n = require("./lib/i18n")

local KIND = "omp-usage.accounts"

local L = i18n.strings(i18n.current(tern))

local function is_usage_pane(title: string): boolean
	for _, t in i18n.titles() do
		if string.sub(title, 1, #t) == t then
			return true
		end
	end
	return false
end

local function open_usage(cx: WindowCx)
	-- Her blok kendi omp süreçlerini çalıştırır; pencere başına bir tane yeter.
	for _, pane in cx.session:panes() do
		if is_usage_pane(pane.title or "") then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		local now = i18n.strings(i18n.current(tern))
		cx:toast("error", now.not_loaded, now.not_loaded_detail)
	end
end

tern.command({
	id = "open",
	title = L.cmd_open,
	icon = "sparkle",
	keys = { "ctrl+alt+shift+u" },
	run = open_usage,
})

-- Açık bloklar yeni dili bir sonraki çizimde (en geç 30 sn) alır; bloğun `l` tuşu hemen.
tern.command({
	id = "lang",
	title = L.cmd_lang,
	icon = "sparkle",
	run = function(cx: WindowCx)
		local lang: i18n.Lang = i18n.other(i18n.current(tern))
		tern.kv.set(i18n.KV_KEY, lang)
		cx:toast("info", i18n.strings(lang).lang_switched)
	end,
})
