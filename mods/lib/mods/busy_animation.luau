--!strict
-- A busy animation for panes and tabs whose agent is working. Tern gives a working
-- tab `.tt.working` (its name flows with Tern's own shimmer) and a terminal running a
-- command `.tn-pane.working` (a `.tn-glow` ring turns along its edge). A working omp
-- pane doesn't get this class; the "Running" dot in its header (`.sdot.live`) gives it
-- away, so it is caught only in panes whose header shows.

local schema = require("../schema")

local num = schema.num

local PANE = ".tn-stage .tn-pane:is(.working, :has(> .tn-head .sdot.live))"
local TAB = ":is(#tabbar .tt.working, #sidebar .nav-row.working)"

local mod: schema.Mod = {
	id = "busy-animation",
	defaults = { style = "both", color = "live", speed = 3 },
	fields = {
		{ key = "style", kind = "choice", options = { "shimmer", "pulse", "both", "quiet" }, style = "segmented" },
		{ key = "color", kind = "color", options = schema.PALETTE_ORDER },
		{ key = "speed", kind = "number", min = 1, max = 10, step = 0.5, unit = "s" },
	},
	css = function(s, _env)
		local c = schema.color(s.color) or "var(--live)"
		local t = num(s.speed)
		local style = s.style
		if style == "quiet" then
			-- Tern's own busy animations go quiet too.
			return table.concat({
				".tn-pane.working .tn-glow { display: none !important; }",
				".tt.working .nm, .tn-vt .nav-row.working .lbl { animation: none !important; color: inherit !important; background: none !important; -webkit-background-clip: border-box !important; background-clip: border-box !important; }",
			}, "\n")
		end
		local css = {}
		if style == "shimmer" or style == "both" then
			-- Tern's edge ring (perimeter-gradient), with a single bright strip at the chosen speed.
			table.insert(
				css,
				`{PANE} .tn-glow \{ opacity: 1 !important; visibility: visible !important; --tn-glow-stops: rgb(from {c} r g b / 8%) 0%, rgb(from {c} r g b / 8%) 55%, {c} 82%, rgb(from {c} r g b / 8%) 100% !important; }`
			)
			table.insert(css, `{PANE} .tn-glow .tn-glow-bloom \{ opacity: 0.35 !important; }`)
			table.insert(
				css,
				`{PANE} .tn-glow :is(.tn-glow-ring, .tn-glow-band) \{ animation-duration: {t}s !important; animation-play-state: running !important; }`
			)
		end
		if style == "pulse" or style == "both" then
			table.insert(
				css,
				`@keyframes mods-busy-pulse \{ 0%, 100% \{ background-color: rgb(from {c} r g b / 4%); box-shadow: inset 0 0 0 1px rgb(from {c} r g b / 15%); } 50% \{ background-color: rgb(from {c} r g b / 22%); box-shadow: inset 0 0 0 1px rgb(from {c} r g b / 75%); } }`
			)
			table.insert(css, `{TAB} \{ animation: mods-busy-pulse {t}s ease-in-out infinite !important; }`)
			table.insert(css, `@keyframes mods-busy-blink \{ 0%, 100% \{ opacity: 1; } 50% \{ opacity: 0.35; } }`)
			table.insert(css, `#tabbar .tn-dk-c[data-st='working'] \{ color: {c} !important; animation: mods-busy-blink {t}s ease-in-out infinite; }`)
		end
		return table.concat(css, "\n")
	end,
}

return mod
