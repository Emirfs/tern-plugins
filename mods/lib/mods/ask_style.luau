--!strict
-- The agent's question/approval UI, where Tern draws it: the question box that
-- replaces the input box of omp's `ask` tool (`omp.editor.ask`), the question and
-- permission dialogs (`omp.overlay.ask`, `omp.overlay.permission`) and the tool
-- card that waits for the user in the chat (`.sf-tool.st-ask`).

local schema = require("../schema")

local DOCK = ".sf-col[data-role^='omp.editor.ask']"
local OVERLAY = ".sf-overlay:is([data-role='omp.overlay.ask'], [data-role='omp.overlay.permission']) .sf-ov-card"
local CARD = ".sf-tool.card.st-ask"

local DENSITY: { [string]: { t: number, x: number, font: number } } = {
	compact = { t = 6, x = 8, font = 13 },
	normal = { t = 12, x = 10, font = 14 },
	spacious = { t = 20, x = 18, font = 15 },
}

local mod: schema.Mod = {
	id = "ask-style",
	defaults = { color = "accent", density = "normal", glow = true },
	fields = {
		{ key = "color", kind = "color", options = schema.PALETTE_ORDER },
		{ key = "density", kind = "choice", options = { "compact", "normal", "spacious" }, style = "segmented" },
		{ key = "glow", kind = "bool" },
	},
	css = function(s, _env)
		local c = schema.color(s.color) or "var(--accent)"
		local d = DENSITY[s.density] or DENSITY.normal
		local glow = if s.glow then `, 0 0 0 4px rgb(from {c} r g b / 14%), 0 10px 30px -12px rgb(from {c} r g b / 55%)` else ""
		local css = {
			`{DOCK}, {OVERLAY} \{ box-shadow: 0 0 0 1.5px {c}{glow} !important; }`,
			`{CARD} \{ background: rgb(from {c} r g b / 6%) !important; box-shadow: inset 0 0 0 1.5px rgb(from {c} r g b / 70%){glow} !important; }`,
			`{CARD} .sf-tool-ic, {CARD} .sf-tool-ask-ic \{ color: {c} !important; }`,
			`.sf-dock {DOCK} \{ --ask-t: {d.t}px !important; --ask-x: {d.x}px !important; }`,
			`{DOCK} > .sf-md[data-role='omp.ask.question'], {OVERLAY} .sf-md[data-role='omp.ask.question'] \{ font-size: {d.font}px !important; }`,
		}
		if s.density == "compact" then
			table.insert(css, `{DOCK} > .sf-list[data-role='omp.ask.options'] .sf-item \{ min-height: 0 !important; padding-top: 2px !important; padding-bottom: 2px !important; }`)
		elseif s.density == "spacious" then
			table.insert(css, `{DOCK} > .sf-list[data-role='omp.ask.options'] .sf-item \{ padding-top: 6px !important; padding-bottom: 6px !important; }`)
		end
		return table.concat(css, "\n")
	end,
}

return mod
