--!strict
-- Pencere yarısı: Hafıza panelini açan (açıksa odaklayan) palet komutu.
local KIND = "hafiza.panel"

tern.command({
	id = "open",
	title = "Hafıza: öneriler ve bugün",
	run = function(cx: WindowCx)
		for _, pane in cx.session:panes() do
			if pane.block == KIND and not pane.parked then
				cx.layout:focus(pane.pane)
				return
			end
		end
		if cx:new_block(KIND, nil, "beside") == nil then
			cx:toast("error", "Hafıza paneli açılamadı", "Eklentinin host yarısı yüklenmemiş; `tern plugin list` ile bakın.")
		end
	end,
})
