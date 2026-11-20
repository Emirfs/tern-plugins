--!strict
-- Focus mode: the tab bar and the status line (widget bar) are hidden and the panes
-- stretch to the window's top edge: in every layout Tern starts the panes `--tn-bar`
-- lower. With "Peek" on, a thin strip stays at the top; when the pointer reaches it,
-- the tab bar (and the window buttons) open over the panes.
-- Horizontal tabs only; the vertical tab rail (`tabs-v`) stays as it is.

local schema = require("../schema")

local mod: schema.Mod = {
	id = "focus-mode",
	defaults = { status = true, heads = false, peek = true },
	fields = {
		{ key = "status", kind = "bool" },
		{ key = "heads", kind = "bool" },
		{ key = "peek", kind = "bool" },
	},
	css = function(s, _env)
		local css = {}
		if s.peek then
			table.insert(css, "html.tabs-h { --tn-bar: 6px !important; }")
			table.insert(
				css,
				"html.tabs-h #tabbar { position: fixed !important; top: 0 !important; left: 0 !important; right: 0 !important; height: 6px !important; overflow: hidden; z-index: 60 !important; opacity: 0; background: var(--pop-bg); box-shadow: var(--pop-shadow); transition: opacity 0.15s ease 0.3s, height 0s linear 0.45s; }"
			)
			table.insert(
				css,
				"html.tabs-h #tabbar:hover, html.tabs-h #tabbar:focus-within { height: 40px !important; opacity: 1; transition: opacity 0.15s ease, height 0s; }"
			)
			-- Window buttons (frameless window): they appear together with the bar.
			table.insert(css, "html.csd.tabs-h .csd-ctl { top: 6px !important; opacity: 0; transition: opacity 0.15s ease 0.3s; }")
			table.insert(css, "html.csd.tabs-h:has(#tabbar:hover) .csd-ctl, html.csd.tabs-h .csd-ctl:hover { opacity: 1; transition-delay: 0s; }")
		else
			table.insert(css, "html.tabs-h { --tn-bar: 4px !important; }")
			table.insert(css, "html.tabs-h #tabbar { display: none !important; }")
			table.insert(css, "html.csd.tabs-h .csd-ctl { display: none !important; }")
		end
		if s.status then
			table.insert(css, "html #widgetbar { display: none !important; }")
			-- With the widget bar open Tern leaves room for it under the stage; that room goes away too.
			table.insert(css, "html.tn-widgets .tn-stage { bottom: 0 !important; }")
		end
		if s.heads then
			table.insert(css, ".tn-stage .tn-pane > .tn-head { display: none !important; }")
		end
		return table.concat(css, "\n")
	end,
}

return mod
