-- Pencere yarısı: kullanım bloğunu yanda açan (ya da bu pencerede zaten
-- açıksa ona odaklanan) palet komutu ve kısayol.

local KIND = "omp-usage.accounts"
local TITLE = "omp kullanım"

local function open_usage(cx: WindowCx)
	-- Her blok kendi omp süreçlerini çalıştırır; pencere başına bir tane yeter.
	for _, pane in cx.session:panes() do
		if string.sub(pane.title or "", 1, #TITLE) == TITLE then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", "omp kullanım bloğu bu host'ta yüklü değil", "`tern plugin list` ile eklentinin durumuna bak.")
	end
end

tern.command({
	id = "open",
	title = "omp kullanımını aç (tüm hesaplar)",
	icon = "sparkle",
	keys = { "ctrl+alt+shift+u" },
	run = open_usage,
})
