--!strict
-- Window half: the palette command and key bind that open the usage block beside
-- the focused pane, or focus it if this window already has one.

local L = require("./lib/text")

local KIND = "omp-usage.accounts"

local function is_usage_pane(title: string): boolean
	return string.sub(title, 1, #L.title) == L.title
end

local function open_usage(cx: WindowCx)
	-- Each block runs its own omp processes; one per window is enough.
	for _, pane in cx.session:panes() do
		if is_usage_pane(pane.title or "") then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside") == nil then
		cx:toast("error", L.not_loaded, L.not_loaded_detail)
	end
end

tern.command({
	id = "open",
	title = L.cmd_open,
	icon = "sparkle",
	keys = { "ctrl+alt+shift+u" },
	run = open_usage,
})
