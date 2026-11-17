--!strict
local check = require("./check")
local fmt = require("../lib/fmt")
local i18n = require("../lib/i18n")

local TR = i18n.strings("tr")
local EN = i18n.strings("en")

-- İki dil aynı anahtarları ve aynı yer tutucuları taşır
do
	local function holders(s: string): string
		local out = {}
		for h in string.gmatch((string.gsub(s, "%%%%", "")), "%%[%d]*[ds]") do
			table.insert(out, (string.gsub(h, "%d", "")))
		end
		return table.concat(out, ",")
	end
	for _, pair in { { TR, EN, "tr→en" }, { EN, TR, "en→tr" } } do
		local a, b, dir = pair[1] :: any, pair[2] :: any, pair[3] :: any
		for key, text in a do
			check.truthy(b[key] ~= nil, `{dir}: key {key} exists in both languages`)
			check.eq(holders(b[key]), holders(text), `{dir}: placeholders of {key}`)
		end
	end
end

-- Dil seçimi
do
	check.eq(i18n.detect(nil, "tr_TR.UTF-8"), "tr", "Turkish locale")
	check.eq(i18n.detect("en", "tr_TR.UTF-8"), "en", "saved choice beats the locale")
	check.eq(i18n.detect(nil, nil), "en", "no locale defaults to English")
	check.eq(i18n.detect("xx", "de_DE"), "en", "unknown saved value is ignored")
	check.eq(i18n.other("tr"), "en", "toggle")

	local kv: { [string]: any } = { lang = "tr" }
	local rt = {
		kv = { get = function(k: string): any return kv[k] end },
		getenv = function(_: string): string? return "en_US" end,
	}
	check.eq(i18n.current(rt), "tr", "current reads the saved choice")
	rt.kv.get = function(_: string): any error("kv.json unreadable") end
	check.eq(i18n.current(rt), "en", "an unreadable store falls back to the locale")
end

-- Biçimler
do
	local now = 1_000_000
	local function at(s: number): number
		return (now + s) * 1000
	end
	check.eq(fmt.until_text(nil, now, TR), "—", "unknown reset")
	check.eq(fmt.until_text(at(-5), now, TR), "şimdi", "past reset")
	check.eq(fmt.until_text(at(30), now, TR), "<1dk", "under a minute")
	check.eq(fmt.until_text(at(125 * 60), now, TR), "2sa05dk", "hours and minutes")
	check.eq(fmt.until_text(at(2 * 86400 + 3 * 3600), now, EN), "2d03h", "days and hours, English")

	check.eq(fmt.pct(0.854, TR), "%85", "Turkish percent sign leads")
	check.eq(fmt.pct(0.854, EN), "85%", "English percent sign trails")

	check.eq(fmt.window_name(5 * 3600 * 1000, TR), "5 saat", "5h window")
	check.eq(fmt.window_name(7 * 86400 * 1000, EN, true), "7d", "7d window, short")
	check.eq(fmt.first_line("a\r\nb"), "a", "first line")
end
