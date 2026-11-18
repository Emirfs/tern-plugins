--!strict
-- What the pane shows when narrow and when wide. The pane is narrow below `threshold` columns (cells);
-- each part is on or off separately for both. Pure, so lune tests check it without Tern.

local Layout = {}

export type Parts = { [string]: boolean }
export type Layout = { threshold: number, narrow: Parts, wide: Parts }

Layout.PARTS = {
	{ id = "toolbar", label = "Araç çubuğu" },
	{ id = "graph", label = "Grafik" },
	{ id = "refs", label = "Dal ve etiket adları" },
	{ id = "author", label = "Yazar" },
	{ id = "age", label = "Zaman" },
	{ id = "hash", label = "Hash" },
	{ id = "detail", label = "Ayrıntı (mesaj, dosyalar)" },
}

Layout.MIN, Layout.MAX, Layout.STEP = 40, 300, 10

function Layout.default(): Layout
	return {
		threshold = 110,
		narrow = { toolbar = false, graph = true, refs = true, author = false, age = true, hash = false, detail = true },
		wide = { toolbar = true, graph = true, refs = true, author = true, age = true, hash = true, detail = true },
	}
end

--- A stored layout made whole: unknown parts dropped, missing ones from the default, threshold clamped.
function Layout.sanitize(raw: any): Layout
	local out = Layout.default()
	if type(raw) ~= "table" then
		return out
	end
	if type(raw.threshold) == "number" then
		out.threshold = math.clamp(math.floor(raw.threshold), Layout.MIN, Layout.MAX)
	end
	for _, mode in { "narrow", "wide" } do
		local given = raw[mode]
		if type(given) == "table" then
			local parts = (out :: any)[mode] :: Parts
			for _, part in Layout.PARTS do
				if type(given[part.id]) == "boolean" then
					parts[part.id] = given[part.id]
				end
			end
		end
	end
	return out
end

function Layout.mode(l: Layout, cols: number): "narrow" | "wide"
	return if cols < l.threshold then "narrow" else "wide"
end

--- The parts shown at `cols` columns.
function Layout.visible(l: Layout, cols: number): Parts
	return if Layout.mode(l, cols) == "narrow" then l.narrow else l.wide
end

--- Flips one part of one mode; returns false for an unknown mode or part.
function Layout.toggle(l: Layout, mode: string, part: string): boolean
	local parts = if mode == "narrow" then l.narrow elseif mode == "wide" then l.wide else nil
	if parts == nil or parts[part] == nil then
		return false
	end
	parts[part] = not parts[part]
	return true
end

return Layout
