--!strict
-- Small assertion helpers: the first failed check stops with an error.

local check = { count = 0 }

local function show(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function check.eq(got: any, want: any, what: string)
	check.count += 1
	if got ~= want then
		error(`{what}: got {show(got)}, want {show(want)}`, 2)
	end
end

function check.truthy(v: any, what: string)
	check.count += 1
	if not v then
		error(`{what}: got {show(v)}`, 2)
	end
end

-- Deep equality: the tables' keys and values match in both directions.
local function same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function check.same(got: any, want: any, what: string)
	check.count += 1
	if not same(got, want) then
		error(`{what}: tables differ`, 2)
	end
end

return check
