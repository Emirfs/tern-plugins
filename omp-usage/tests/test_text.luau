--!strict
local check = require("./check")
local fmt = require("../lib/fmt")
local L = require("../lib/text")

-- Formats
do
	local now = 1_000_000
	local function at(s: number): number
		return (now + s) * 1000
	end
	check.eq(fmt.until_text(nil, now, L), "—", "unknown reset")
	check.eq(fmt.until_text(at(-5), now, L), "now", "past reset")
	check.eq(fmt.until_text(at(30), now, L), "<1m", "under a minute")
	check.eq(fmt.until_text(at(125 * 60), now, L), "2h05m", "hours and minutes")
	check.eq(fmt.until_text(at(2 * 86400 + 3 * 3600), now, L), "2d03h", "days and hours")

	check.eq(fmt.pct(0.854, L), "85%", "percent sign trails")

	check.eq(fmt.window_name(5 * 3600 * 1000, L), "5 hours", "5h window")
	check.eq(fmt.window_name(7 * 86400 * 1000, L, true), "7d", "7d window, short")
	check.eq(fmt.first_line("a\r\nb"), "a", "first line")
end
