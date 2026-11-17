--!strict
local check = require("./check")
local schema = require("../lib/schema")

local FIELDS: { schema.Field } = {
	{ key = "style", kind = "choice", options = { "a", "b" } },
	{ key = "n", kind = "number", min = 0, max = 10, step = 0.5 },
	{ key = "on", kind = "bool" },
	{ key = "c", kind = "color" },
	{ key = "map", kind = "colors" },
	{ key = "path", kind = "path" },
}
local DEFAULTS = { style = "a", n = 4, on = false, c = "accent", map = {}, path = "" }

do
	local s = schema.normalize(FIELDS, DEFAULTS, nil)
	check.same(s, DEFAULTS, "missing settings are the defaults")

	s = schema.normalize(FIELDS, DEFAULTS, {
		style = "zzz",
		n = 99,
		on = "yes",
		c = "red; } body { display:none",
		map = { mine = "#ff8800", work = "url(x)", ["a b"] = "red", default = "none" },
		path = "C:\\x\ny.png",
		extra = 1,
	})
	check.eq(s.style, "a", "unknown choice falls back")
	check.eq(s.n, 10, "a number is clamped to its range")
	check.eq(s.on, false, "a non-boolean switch falls back")
	check.eq(s.c, "accent", "CSS injection in a color falls back")
	check.eq(s.map.mine, "#ff8800", "a hex profile color stays")
	check.eq(s.map.default, "none", "'none' stays")
	check.eq(s.map.work, nil, "a non-color profile color is dropped")
	check.eq(s.map["a b"], nil, "a profile name with a space is dropped")
	check.eq(s.path, "", "a path with a control character falls back")
	check.eq(s.extra, nil, "unknown keys are dropped")

	check.eq(schema.normalize(FIELDS, DEFAULTS, { n = 3.26 }).n, 3.5, "a number snaps to its step")
	check.eq(schema.normalize(FIELDS, DEFAULTS, { n = 0 / 0 }).n, 4, "NaN falls back")
	check.eq(schema.normalize(FIELDS, DEFAULTS, { n = math.huge }).n, 4, "infinity falls back")
end

do
	check.eq(schema.color("teal"), "#2ec4c4", "palette name")
	check.eq(schema.color("#ABC"), "#abc", "short hex, lowercased")
	check.eq(schema.color("#12345678"), "#12345678", "hex with alpha")
	check.eq(schema.color("#12345"), nil, "five hex digits")
	check.eq(schema.color("rgb(1,2,3)"), nil, "functions are not accepted")
	check.eq(schema.color(12), nil, "not a string")
end

do
	check.eq(schema.css_string('a"b\\c'), '"a\\"b\\\\c"', "quotes and backslashes are escaped")
	check.eq(schema.css_string("a\nb"), '"a\\a b"', "a newline is a CSS escape")
	check.eq(schema.num(12), "12", "integer")
	check.eq(schema.num(0.35), "0.35", "fraction without trailing zeros")
	check.eq(schema.num(1 / 3), "0.333", "three decimals")
end

return nil
