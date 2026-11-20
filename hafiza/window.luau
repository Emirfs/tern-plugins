--!strict
-- Window half: the palette command that opens the Memory panel (or focuses it if already open).
local KIND = "hafiza.panel"

tern.command({
	id = "open",
	title = "Memory: suggestions and today",
	run = function(cx: WindowCx)
		for _, pane in cx.session:panes() do
			if pane.block == KIND and not pane.parked then
				cx.layout:focus(pane.pane)
				return
			end
		end
		if cx:new_block(KIND, nil, "beside") == nil then
			cx:toast("error", "Could not open the Memory panel", "The plugin's host half is not loaded; check `tern plugin list`.")
		end
	end,
})
