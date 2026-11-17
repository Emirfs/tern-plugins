--!strict
-- Sekmelerin görünümü. Tern etkin sekmeyi `.tt.on` ile, bazı düzenlerde altına
-- kayan bir `.tb-pill` ile çizer; o kayan dolgu her biçimde gizlenir ki biçim
-- sekmenin kendisinde dursun.

local schema = require("../schema")

local STYLES = { "pill", "underline", "block", "outline", "minimal" }

local mod: schema.Mod = {
	id = "tab-style",
	defaults = { style = "pill", color = "accent", dim = 70 },
	fields = {
		{ key = "style", kind = "choice", options = STYLES, style = "menu" },
		{ key = "color", kind = "color", options = schema.PALETTE_ORDER },
		{ key = "dim", kind = "number", min = 30, max = 100, step = 5, unit = "%" },
	},
	css = function(s, _env)
		local c = schema.color(s.color) or "var(--accent)"
		local tab = "html #tabbar .tt"
		local on = "html #tabbar .tt.on"
		local css = {
			"html #tabbar .tb-pill { display: none !important; }",
			`{tab}:not(.on) \{ opacity: {schema.num(s.dim / 100)}; }`,
			`{tab}:not(.on):hover \{ opacity: 1; }`,
		}
		local style = s.style
		if style == "pill" then
			table.insert(css, `{tab} \{ border-radius: 999px !important; }`)
			table.insert(
				css,
				`{on} \{ background: rgb(from {c} r g b / 16%) !important; color: var(--t1) !important; box-shadow: inset 0 0 0 1px rgb(from {c} r g b / 45%) !important; }`
			)
		elseif style == "underline" then
			table.insert(css, `{tab} \{ border-radius: 0 !important; background: transparent !important; box-shadow: none !important; }`)
			table.insert(css, `{on}::before, {on}::after \{ opacity: 0 !important; }`)
			table.insert(css, `{tab}:hover \{ box-shadow: inset 0 -2px 0 var(--l3) !important; }`)
			table.insert(css, `{on} \{ background: transparent !important; box-shadow: inset 0 -2px 0 {c} !important; color: var(--t1) !important; }`)
		elseif style == "block" then
			table.insert(css, `{tab} \{ border-radius: 4px !important; background: var(--l1) !important; margin: 0 1px; }`)
			table.insert(css, `{on} \{ background: {c} !important; color: #fff !important; box-shadow: none !important; }`)
			table.insert(css, `{on} :is(.nm, .ico, .tn-tx) \{ color: #fff !important; }`)
		elseif style == "outline" then
			table.insert(css, `{tab} \{ border-radius: 8px !important; }`)
			table.insert(css, `{on} \{ background: transparent !important; box-shadow: inset 0 0 0 1.5px {c} !important; color: var(--t1) !important; }`)
		elseif style == "minimal" then
			table.insert(css, `{tab} \{ background: transparent !important; box-shadow: none !important; }`)
			table.insert(css, `{on} \{ background: transparent !important; box-shadow: none !important; color: {c} !important; font-weight: 600; }`)
		end
		return table.concat(css, "\n")
	end,
}

return mod
