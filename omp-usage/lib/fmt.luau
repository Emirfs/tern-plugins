--!strict
-- Formatting: window name, time until refresh, percentage. Pure; the text comes
-- from the `L` (lib/text) table, the current time from the caller.

local fmt = {}

function fmt.first_line(text: string): string
	return string.match(text, "[^\r\n]+") or ""
end

--- The name of a window duration: under 48 hours in hours, above in days ("5 hours", "7 days").
function fmt.window_name(ms: number?, L: { [string]: string }, short: boolean?): string
	if not ms then
		return "?"
	end
	local hours = ms / 3600000
	if hours < 48 then
		return string.format(if short then L.hours_short else L.hours, math.floor(hours + 0.5))
	end
	return string.format(if short then L.days_short else L.days, math.floor(hours / 24 + 0.5))
end

--- The time left until `resets_ms` (epoch ms), as of `now` (epoch s).
function fmt.until_text(resets_ms: number?, now: number, L: { [string]: string }): string
	if type(resets_ms) ~= "number" then
		return "—"
	end
	local s = math.floor(resets_ms / 1000 - now)
	if s <= 0 then
		return L.until_now
	elseif s < 60 then
		return L.until_lt_min
	elseif s < 3600 then
		return string.format(L.until_min, s // 60)
	elseif s < 86400 then
		return string.format(L.until_hour, s // 3600, (s % 3600) // 60)
	end
	return string.format(L.until_day, s // 86400, (s % 86400) // 3600)
end

--- A percentage as text: "85%".
function fmt.pct(fraction: number, L: { [string]: string }): string
	return string.format(L.pct, math.floor(fraction * 100 + 0.5))
end

return fmt
