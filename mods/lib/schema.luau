--!strict
-- Mod ayarlarının şeması ve doğrulaması. kv'den gelen her değer CSS'e girmeden
-- önce buradan geçer: seçenek dışı seçim, aralık dışı sayı, renk olmayan metin
-- varsayılana döner. CSS'e kullanıcı metni ancak buradaki denetimlerle girer.

export type Kind = "choice" | "number" | "bool" | "color" | "colors" | "path"

export type Field = {
	key: string,
	kind: Kind,
	-- choice: geçerli değerler, sırasıyla.
	options: { string }?,
	-- choice: "segmented" kısa seçenekler, "menu" uzun liste (varsayılan Tern seçer).
	style: ("segmented" | "menu")?,
	-- number
	min: number?,
	max: number?,
	step: number?,
	unit: string?,
}

export type Settings = { [string]: any }

-- profile-accent: omp profili çalışan bir pane.
export type PaneEnv = {
	pane: number,
	title: string,
	profile: string,
	focused: boolean,
}

-- Hareketli duvar kağıdı: ffmpeg'in tek bir sprite sheet'e dizdiği kareler.
export type Anim = {
	url: string,
	cols: number,
	rows: number,
	frames: number,
	fps: number,
	-- Bir karenin en/boy oranı (genişlik / yükseklik).
	ratio: number,
}

-- Mod CSS'inin pencereden aldığı, ayar dışı bilgiler.
export type Env = {
	panes: { PaneEnv },
	wallpaper_url: string?,
	wallpaper_anim: Anim?,
}

export type Mod = {
	id: string,
	defaults: Settings,
	fields: { Field },
	css: (s: Settings, env: Env) -> string?,
}

local schema = {}

-- Renk alanlarının adlı seçenekleri; Tern'in tema değişkenleri ya da sabit tonlar.
schema.PALETTE = {
	accent = "var(--accent)",
	live = "var(--live)",
	blue = "#4c8dff",
	violet = "#a86af4",
	pink = "#ec5fa6",
	red = "#e5484d",
	orange = "#f0883e",
	yellow = "#e8b931",
	green = "#3ecf8e",
	teal = "#2ec4c4",
	gray = "#8b8d98",
}
schema.PALETTE_ORDER = { "accent", "live", "blue", "violet", "pink", "red", "orange", "yellow", "green", "teal", "gray" }

-- `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`.
function schema.is_hex(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local hex = string.match(v, "^#(%x+)$")
	return hex ~= nil and (#hex == 3 or #hex == 4 or #hex == 6 or #hex == 8)
end

--- Renk değerinin CSS karşılığı: palet adı ya da onaltılık renk; başka her şey nil.
function schema.color(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local named = (schema.PALETTE :: { [string]: string })[v]
	if named then
		return named
	end
	if schema.is_hex(v) then
		return string.lower(v)
	end
	return nil
end

-- Profil adı: omp'nin `~/.omp/profiles/<ad>` klasör adı gibi, CSS'e girmez ama sınırlı tutulur.
function schema.is_profile_name(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= 64 and string.match(v, "^[%w%._%-]+$") ~= nil
end

local function in_options(field: Field, v: any): boolean
	for _, o in field.options or ({} :: { string }) do
		if o == v then
			return true
		end
	end
	return false
end

local function clean_number(field: Field, v: any): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	local lo = field.min or -math.huge
	local hi = field.max or math.huge
	local n = math.clamp(v, lo, hi)
	local step = field.step
	if step and step > 0 then
		local base = if field.min then field.min else 0
		n = base + math.floor((n - base) / step + 0.5) * step
		n = math.clamp(n, lo, hi)
		-- Kayan nokta artığı (0.30000000000000004) CSS'e çıkmasın.
		n = math.floor(n * 1000 + 0.5) / 1000
	end
	return n
end

-- Dosya yolu: kontrol karakteri yok, makul uzunluk. CSS'e yol değil, okunan dosyanın
-- base64'ü girer; yol yalnız okunur.
local function clean_path(v: any): string?
	if type(v) ~= "string" or #v > 1024 or string.find(v, "%c") then
		return nil
	end
	return v
end

local function clean_one(field: Field, v: any): (boolean, any)
	local kind = field.kind
	if kind == "bool" then
		return type(v) == "boolean", v
	elseif kind == "choice" then
		return in_options(field, v), v
	elseif kind == "number" then
		local n = clean_number(field, v)
		return n ~= nil, n
	elseif kind == "color" then
		return schema.color(v) ~= nil, v
	elseif kind == "path" then
		local p = clean_path(v)
		return p ~= nil, p
	elseif kind == "colors" then
		if type(v) ~= "table" then
			return false, nil
		end
		local out: { [string]: string } = {}
		for name, c in v do
			if schema.is_profile_name(name) and (c == "none" or schema.color(c) ~= nil) then
				out[name] = c
			end
		end
		return true, out
	end
	return false, nil
end

--- Bir modun kayıtlı ayarları (`raw`, kv'den, her şey olabilir) doğrulanmış haliyle:
--- eksik ya da geçersiz her alan varsayılanını alır, bilinmeyen anahtarlar düşer.
function schema.normalize(fields: { Field }, defaults: Settings, raw: any): Settings
	local out: Settings = {}
	local src = if type(raw) == "table" then raw else {}
	for _, f in fields do
		local ok, v = clean_one(f, src[f.key])
		if ok and v ~= nil then
			out[f.key] = v
		else
			out[f.key] = defaults[f.key]
		end
	end
	return out
end

--- Tek bir alana gelen yeni değer geçerliyse temizlenmiş hali, değilse nil.
function schema.accept(field: Field, v: any): any
	local ok, clean = clean_one(field, v)
	if ok then
		return clean
	end
	return nil
end

function schema.field(fields: { Field }, key: string): Field?
	for _, f in fields do
		if f.key == key then
			return f
		end
	end
	return nil
end

--- CSS çift tırnaklı dizgesi: ters bölü, tırnak ve satır sonları kaçırılır.
function schema.css_string(s: string): string
	local out = string.gsub(s, "[\\\"\n\r\f]", function(c: string): string
		if c == "\\" then
			return "\\\\"
		elseif c == '"' then
			return '\\"'
		end
		return string.format("\\%x ", string.byte(c))
	end)
	return '"' .. out .. '"'
end

--- Sayının CSS'e kısa yazımı (12, 12.5).
function schema.num(n: number): string
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	local s = string.format("%.3f", n)
	s = string.gsub(s, "0+$", "")
	return s
end

return schema
