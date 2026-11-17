--!strict
local check = require("./check")
local i18n = require("../lib/i18n")
local panel = require("../lib/panel")
local registry = require("../lib/registry")
local sprite = require("../lib/sprite")

local function data(over: { [string]: any }?): panel.Data
	local d: panel.Data = {
		lang = "en",
		on = {},
		cfg = nil,
		look = { accent = "theme", corners = "theme" },
		user = { { id = "user-dark", file = "dark.css", title = "Dark" } },
		user_dir = "C:/data/user-mods",
		profiles = { "default", "mine" },
	}
	for k, v in over or ({} :: { [string]: any }) do
		(d :: any)[k] = v
	end
	return d
end

local function only(ws: { panel.Write }): panel.Write
	check.eq(#ws, 1, "one write")
	return ws[1]
end

-- Satır değişiklikleri kv yazımlarına.
do
	local w = only(panel.change(data(), "on.wallpaper", true))
	check.eq(w.key, "on", "switch writes the on table")
	check.eq(w.value.wallpaper, true, "mod turned on")
	w = only(panel.change(data({ on = { wallpaper = true, ["user-dark"] = true } }), "on.wallpaper", false))
	check.eq(w.value.wallpaper, nil, "mod turned off")
	check.eq(w.value["user-dark"], true, "other mods untouched")
	check.eq(only(panel.change(data(), "on.user-dark", true)).value["user-dark"], true, "user mod switch")
	check.eq(#panel.change(data(), "on.nope", true), 0, "unknown mod ignored")

	w = only(panel.change(data({ cfg = { composer = { font = 15 } } }), "set.composer.radius", 20))
	check.eq(w.key, "cfg", "setting writes cfg")
	check.eq(w.value.composer.radius, 20, "new value")
	check.eq(w.value.composer.font, 15, "earlier value kept")
	check.eq(#panel.change(data(), "set.composer.radius", "big"), 0, "invalid value ignored")
	check.eq(only(panel.change(data(), "set.composer.radius", 99)).value.composer.radius, 28, "clamped")
	check.eq(only(panel.change(data({ cfg = { composer = { radius = 3 } } }), "set.composer.radius", nil)).value.composer.radius, 12, "nil resets to default")
	check.eq(#panel.change(data(), "set.composer.bogus", 1), 0, "unknown field ignored")

	w = only(panel.change(data(), "set.profile-accent.colors.mine", "pink"))
	check.eq(w.value["profile-accent"].colors.mine, "pink", "profile color set")
	w = only(panel.change(data({ cfg = w.value }), "set.profile-accent.colors.mine", "auto"))
	check.eq(w.value["profile-accent"].colors.mine, nil, "auto clears it")
	check.eq(#panel.change(data(), "set.profile-accent.colors.mine", "url(x)"), 0, "bad color ignored")
	check.eq(#panel.change(data(), "set.profile-accent.colors.a b", "red"), 0, "bad profile name ignored")

	check.eq(only(panel.change(data(), "lang", "tr")).value, "tr", "language")
	check.eq(#panel.change(data(), "lang", "de"), 0, "unknown language ignored")
	check.eq(only(panel.change(data(), "look.corners", "round")).value.corners, "round", "appearance")
	check.eq(#panel.change(data(), "look.accent", "url(x)"), 0, "bad appearance value ignored")

	local p = (panel.preset("presenter") :: { panel.Write })[1]
	check.eq(p.value["privacy-blur"] and p.value["focus-mode"], true, "preset turns its mods on")
	check.eq(panel.preset("nope"), nil, "unknown preset")
end

-- Sayfanın satırları: her satır kimliği change'in tanıdığı bir biçimde.
do
	local props = panel.props(data({ on = { composer = true } }), "mods", nil)
	check.eq(props.page, "mods", "mods page")
	check.eq(props.pages[2].changed, 1, "count of mods on")
	local seen = 0
	for _, sec in props.sections do
		for _, row in sec.rows do
			seen += 1
			check.truthy(type(row.label) == "string" and row.label ~= "", `{row.id} has a label`)
			check.truthy(row.control and type(row.control.k) == "string", `{row.id} has a control`)
		end
	end
	check.truthy(seen > 40, "every mod and field has a row")
	local look = panel.props(data(), "look", nil)
	check.eq(look.sections[1].rows[1].id, "lang", "language row first")
	check.eq(panel.props(data(), "bogus", nil).page, "look", "unknown page shows appearance")
end

-- Kullanıcı modları.
do
	check.eq(registry.user_id("My Theme.CSS"), "user-my-theme", "slug")
	check.eq(registry.user_id("notes.txt"), nil, "not CSS")
	check.eq(registry.user_id("---.css"), nil, "no letters")
	check.eq(registry.user_title("/* title: Neon tabs */\n.a{}", "neon.css"), "Neon tabs", "title comment")
	check.eq(registry.user_title("/*\n  Title: Big\n  by me\n*/", "big.css"), "Big", "title on a later line")
	check.eq(registry.user_title(".a{}", "plain.css"), "plain", "file name without the comment")
	local mods = registry.user_mods({ "b.css", "a b.css", "a-b.css", "x.txt" }, function(_f: string): string?
		return nil
	end)
	check.eq(#mods, 3, "CSS files only")
	check.eq(mods[1].id, "user-a-b", "sorted by file name")
	check.eq(mods[2].id, "user-a-b-2", "same slug gets a suffix")
	check.eq(registry.enabled({ wallpaper = true, x = false, ["a b"] = true }).wallpaper, true, "enabled")
	check.eq(registry.enabled("junk").wallpaper, nil, "junk is empty")
end

-- Sprite sheet planı.
do
	local p = sprite.plan(1920, 1080, 4, 25, 100) :: sprite.Plan
	check.eq(p.frames, 48, "frames capped")
	check.eq(p.fps, 12, "fps capped")
	check.truthy(p.cols * p.w <= sprite.MAX_SIDE and p.rows * p.h <= sprite.MAX_SIDE, "sheet fits 4096 px")
	check.eq(p.w % 2 + p.h % 2, 0, "even frame size")
	local small = sprite.plan(320, 180, 2, 6, 12) :: sprite.Plan
	check.eq(small.w, 320, "small frames keep their size")
	check.eq(small.frames, 12, "duration × fps")
	check.eq(sprite.plan(320, 180, 0, nil, 1), nil, "a single frame is a still image")
	check.eq(sprite.rate("100/7"), 100 / 7, "ffprobe rate")
	check.eq(sprite.rate("0/0"), nil, "zero denominator")
end

-- Diller: aynı anahtarlar, her modun ve alanının etiketi.
do
	local tr, en = i18n._STR.tr, i18n._STR.en
	for k in tr do
		check.truthy(en[k] ~= nil, "en has " .. k)
	end
	for k in en do
		check.truthy(tr[k] ~= nil, "tr has " .. k)
	end
	for _, m in registry.BUILTIN do
		for _, L in { tr, en } do
			check.truthy(L[m.id .. ".title"] and L[m.id .. ".desc"], m.id .. " title and description")
			for _, f in m.fields do
				if f.kind ~= "colors" then
					check.truthy(L[`{m.id}.{f.key}`] ~= nil, `{m.id}.{f.key} label`)
				end
			end
		end
	end
	check.eq(i18n.detect(nil, "tr_TR.UTF-8"), "tr", "Turkish locale")
	check.eq(i18n.detect(nil, nil), "en", "no locale is English")
	check.eq(i18n.detect("tr", "en_US"), "tr", "saved choice wins")
end

return nil
