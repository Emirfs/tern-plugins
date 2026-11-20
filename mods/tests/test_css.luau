--!strict
local check = require("./check")
local registry = require("../lib/registry")
local schema = require("../lib/schema")
local appearance = require("../lib/appearance")

local EMPTY: schema.Env = { panes = {} }

local function balanced(css: string): boolean
	local open = select(2, string.gsub(css, "{", ""))
	local close = select(2, string.gsub(css, "}", ""))
	return open == close
end

local function has(css: string?, needle: string): boolean
	return css ~= nil and string.find(css, needle, 1, true) ~= nil
end

local function settings(id: string, over: { [string]: any }?): schema.Settings
	local m = registry.builtin(id) :: schema.Mod
	return registry.settings(m, { [id] = over or {} })
end

local function css(id: string, over: { [string]: any }?, env: schema.Env?): string?
	local m = registry.builtin(id) :: schema.Mod
	return m.css(settings(id, over), env or EMPTY)
end

-- Each mod, with every option value: balanced braces, no formatting leftovers.
for _, m in registry.BUILTIN do
	local variants: { { [string]: any } } = { {} }
	for _, f in m.fields do
		for _, o in f.options or ({} :: { string }) do
			if f.kind == "choice" then
				table.insert(variants, { [f.key] = o })
			end
		end
		if f.kind == "bool" then
			table.insert(variants, { [f.key] = not m.defaults[f.key] })
		end
	end
	for _, v in variants do
		local out = m.css(registry.settings(m, { [m.id] = v }), EMPTY)
		if out then
			local what = `{m.id} {next(v) or "defaults"}`
			check.truthy(balanced(out), what .. ": balanced braces")
			check.eq(string.find(out, "nil", 1, true), nil, what .. ": no nil in CSS")
			check.eq(string.find(out, "%%[ds]"), nil, what .. ": no format leftovers")
		end
	end
end

do
	local out = css("compact-tabs", { height = 28 })
	check.truthy(has(out, "--tn-bar: max(20px, calc(28px"), "bar height goes into --tn-bar")
	check.truthy(has(out, ".tb-blocks { display: none"), "block shortcuts hidden by default")
	check.eq(has(css("compact-tabs", { blocks = true }), ".tb-blocks"), false, "block shortcuts kept on request")
end

do
	local out = css("tab-style", { style = "underline", color = "#ff0000" })
	check.truthy(has(out, "inset 0 -2px 0 #ff0000"), "underline in the chosen color")
	check.truthy(has(css("tab-style", { style = "pill" }), "var(--accent)"), "accent by default")
end

do
	local env: schema.Env = {
		panes = {
			{ pane = 2422361554951, title = '[mine] "GIT"', profile = "mine", focused = true },
			{ pane = 7, title = "x", profile = "default", focused = false },
			{ pane = 8, title = "", profile = "work", focused = false },
		},
	}
	local out = css("profile-accent", { colors = { mine = "#112233", work = "green" } }, env) :: string
	check.truthy(has(out, 'data-pane="2422361554951"'), "large pane ids are written as integers")
	check.truthy(has(out, '[title="[mine] \\"GIT\\""]'), "the pane title is a quoted CSS string")
	check.eq(has(out, 'data-pane="7"'), false, "default has no color unless chosen")
	check.truthy(has(out, 'data-pane="8"'), "an untitled pane still colors its tab")
	check.eq(has(out, '[title=""]'), false, "an untitled pane has no pane rule")
	-- The focused pane's rules go last: in the same tab its color wins.
	check.truthy((string.find(out, "#112233", 1, true) :: number) > (string.find(out, "#3ecf8e", 1, true) :: number), "focused pane last")

	local edge_only = css("profile-accent", { style = "edge", colors = { mine = "red" } }, env) :: string
	check.eq(has(edge_only, "color-mix"), false, "edge style has no tint")
	check.eq(css("profile-accent", { colors = { default = "none" } }, { panes = { env.panes[2] } }), nil, "nothing to color is nil")
	local auto = css("profile-accent", {}, { panes = { env.panes[3] } })
	check.truthy(auto ~= nil, "a profile without a chosen color gets one from its name")
end

do
	check.truthy(has(css("focus-mode", { peek = false }), "#tabbar { display: none"), "no peek hides the tab bar")
	check.truthy(has(css("focus-mode"), "#tabbar:hover"), "peek shows the bar on hover")
end

do
	local out = css("privacy-blur", { strength = 9 })
	check.truthy(has(out, "blur(9px)"), "blur strength")
	check.truthy(has(out, "plugin.omp-usage.accounts"), "omp usage pane is blurred")
	check.truthy(has(out, ":hover"), "unblurred on hover")
	check.eq(has(css("privacy-blur", { hover = false }), ":hover"), false, "no hover rule when off")
	local none = css("privacy-blur", { tabs = false, heads = false, status = false, usage = false, accounts = false })
	check.eq(none, nil, "nothing selected is nil")
end

do
	check.truthy(has(css("pane-shape", { gap = 10, radius = 0 }), "--tn-tile-gap: calc(5px"), "the gap is split between neighbours")
end

do
	check.eq(css("wallpaper", { source = "image", image = "C:/x.png" }), nil, "an unread image draws nothing")
	local img = css("wallpaper", { source = "image", image = "C:/x.png", fit = "tile" }, { panes = {}, wallpaper_url = 'data:image/png;base64,AA"' }) :: string
	check.truthy(has(img, 'url("data:image/png;base64,AA\\"")'), "the data URL is a quoted CSS string")
	check.truthy(has(img, "repeat !important"), "tile repeats")
	check.truthy(has(img, "main#panel { background: transparent"), "the panel is cleared")
	local anim = css("wallpaper", { source = "image", image = "C:/x.gif" }, {
		panes = {},
		wallpaper_anim = { url = "data:image/jpeg;base64,AA", cols = 3, rows = 2, frames = 5, fps = 10, ratio = 2 },
	}) :: string
	local _, keys = string.gsub(anim, "%d+%% {", "")
	check.eq(keys, 5, "one keyframe per frame")
	check.truthy(has(anim, "0.5s step-end infinite"), "frames / fps seconds per loop")
	check.truthy(has(anim, "calc(3 * max(100vw, 2 * 100vh))"), "the sheet is sized so one frame covers the window")
	check.truthy(has(css("wallpaper", { speed = 20 }), "mods-wp-drift 20s"), "gradient speed")
	check.eq(has(css("wallpaper", { bars = false }), "#tabbar"), false, "no bar shade when off")
end

do
	check.truthy(has(css("composer", { status = "hide" }), "[data-role='omp.hud'] { display: none"), "status row hidden")
	check.truthy(has(css("composer", { font = 16 }), "font-size: 16px"), "composer text size")
end

do
	check.truthy(has(css("ask-style", { color = "pink" }), "#ec5fa6"), "ask border color")
	check.eq(has(css("ask-style", { glow = false }), "0 0 0 4px"), false, "no glow when off")
end

do
	local quiet = css("busy-animation", { style = "quiet" }) :: string
	check.truthy(has(quiet, ".tn-glow { display: none"), "quiet silences Tern's glow")
	check.eq(has(quiet, "@keyframes"), false, "quiet adds no animation")
	check.truthy(has(css("busy-animation", { style = "pulse", speed = 2 }), "mods-busy-pulse 2s"), "pulse speed")
end

do
	check.eq(appearance.css(appearance.normalize(nil)), nil, "theme defaults add nothing")
	local out = appearance.css(appearance.normalize({ accent = "green", corners = "square" })) :: string
	check.truthy(has(out, "--accent: #3ecf8e"), "accent override")
	check.truthy(has(out, "--r-card: 3px"), "square corners")
	check.eq(appearance.normalize({ accent = "url(x)" }).accent, "theme", "bad accent falls back")
	check.eq(appearance.accept("accent", "theme"), "theme", "theme is accepted")
	check.eq(appearance.accept("corners", "pointy"), nil, "unknown corners rejected")
end

return nil
