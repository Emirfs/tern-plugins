--!strict
-- omp profiline göre vurgu rengi. Hangi pane'in hangi profili çalıştırdığını
-- pencere yarısı `tern inspect --json`dan bulur (env.panes); burada yalnız CSS:
-- sekmede pane'in program simgesi `.tn-dk-c[data-pane=<id>]` taşır, sekmenin
-- kendisi `:has()` ile ondan bulunur. Sahnedeki pane'lerin kimlik niteliği yok;
-- başlıklarındaki `.tn-head[title]` pane başlığıyla eşleşir. Başlık çubuğu
-- görünmeyen pane (tek pane'li sekme, `pane_headers` kapalı) renk almaz.

local schema = require("../schema")

-- Rengi seçilmemiş profiller için sabit sıra: aynı ad her yerde aynı renk.
local AUTO = { "violet", "orange", "teal", "pink", "green", "yellow", "blue", "red" }

--- Profilin rengi (CSS) ya da nil (renksiz): seçilen renk, yoksa `default` renksiz,
--- diğerleri adlarından türeyen sabit bir palet rengi.
local function color_for(colors: { [string]: string }, profile: string): string?
	local chosen = colors[profile]
	if chosen == "none" then
		return nil
	end
	if chosen then
		return schema.color(chosen)
	end
	if profile == "default" then
		return nil
	end
	local h = 0
	for i = 1, #profile do
		h = (h * 31 + string.byte(profile, i)) % 2147483647
	end
	return schema.color(AUTO[h % #AUTO + 1])
end

local function css(s: schema.Settings, env: schema.Env): string?
	local colors: { [string]: string } = s.colors
	local edge = s.style ~= "tint"
	local tint = s.style ~= "edge"
	-- Odaktaki pane'ler sona: aynı sekmede iki profil varsa sekme odaktakinin rengini alır.
	local ordered = table.clone(env.panes)
	table.sort(ordered, function(a, b)
		if a.focused ~= b.focused then
			return not a.focused
		end
		return a.pane < b.pane
	end)
	local out = {}
	for _, p in ordered do
		local c = color_for(colors, p.profile)
		if c then
			local id = string.format("%.0f", p.pane)
			if s.tabs then
				local tab = `:is(#tabbar .tt, #sidebar .nav-row):has(.tn-dk-c[data-pane="{id}"])`
				table.insert(out, `#tabbar .tn-dk-c[data-pane="{id}"] \{ color: {c} !important; }`)
				local shadow = if edge then `inset 0 -2px 0 {c}` else "none"
				local bg = if tint then `background-color: rgb(from {c} r g b / 16%) !important; ` else ""
				table.insert(out, `{tab} \{ {bg}box-shadow: {shadow} !important; }`)
			end
			if s.panes and p.title ~= "" then
				local pane = `.tn-stage .tn-pane:has(> .tn-head[title={schema.css_string(p.title)}])`
				if edge then
					table.insert(out, `{pane} > .tn-body \{ box-shadow: inset 0 0 0 1.5px {c} !important; }`)
					table.insert(out, `{pane} > .tn-head \{ box-shadow: inset 0 2px 0 {c} !important; }`)
				end
				if tint then
					table.insert(out, `{pane} > .tn-head \{ background-color: color-mix(in srgb, {c} 18%, var(--panel)) !important; }`)
					table.insert(out, `{pane} > .tn-head .tn-title \{ color: {c} !important; }`)
				end
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

local mod: schema.Mod = {
	id = "profile-accent",
	defaults = { style = "edge", tabs = true, panes = true, colors = {} },
	fields = {
		{ key = "style", kind = "choice", options = { "edge", "tint", "both" }, style = "segmented" },
		{ key = "tabs", kind = "bool" },
		{ key = "panes", kind = "bool" },
		{ key = "colors", kind = "colors" },
	},
	css = css,
}

return mod
