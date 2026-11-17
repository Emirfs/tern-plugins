--!strict
-- Ayar paneli: Tern'in yerel ayar sayfası (`prefs` düğümü, omp'nin /settings'i
-- de bunu çizer) için veriler ve satır değişikliklerinin kv'ye çevrilmesi.
-- Saf: kv'yi çağıran okur/yazar, burası yalnız tablo üretir.
--
-- Satır kimlikleri (Tern değişiklikte `item` olarak geri yollar):
--   lang                     dil
--   look.<alan>              Görünüm ayarı
--   on.<mod>                 modu aç/kapat (kullanıcı modları da)
--   set.<mod>.<alan>         mod ayarı
--   set.<mod>.colors.<profil>  profile-accent'in profil rengi
-- Eylemler (`act`): preset=<ad>, alloff, folder, pick=<mod>.<alan>

local appearance = require("./appearance")
local i18n = require("./i18n")
local registry = require("./registry")
local schema = require("./schema")

export type Data = {
	lang: i18n.Lang,
	on: { [string]: boolean },
	-- kv'deki ham `cfg` (her şey olabilir); satırlar normalize edilmiş halini gösterir.
	cfg: any,
	look: schema.Settings,
	user: { registry.UserMod },
	user_dir: string,
	profiles: { string },
	-- Duvar kağıdı görselinin satırının ikinci bilgisi (kare sayısı, hata…).
	image_note: string?,
}

-- kv'ye yazılacak bir değer.
export type Write = { key: string, value: any }

local panel = {}

local function color_options(L: { [string]: string }, names: { string }, value: any): { any }
	local opts = {}
	for _, name in names do
		table.insert(opts, { value = name, label = L["color." .. name] or name })
	end
	if type(value) == "string" and schema.is_hex(value) then
		table.insert(opts, 1, { value = value, label = value })
	end
	return opts
end

local function shown(L: { [string]: string }, scope: string, f: schema.Field, v: any): string
	if f.kind == "bool" then
		return if v then L.on else "—"
	elseif f.kind == "number" then
		return schema.num(v) .. (f.unit or "")
	elseif f.kind == "color" then
		return L["color." .. tostring(v)] or tostring(v)
	elseif f.kind == "choice" then
		return i18n.option(L, scope, f.key, v)
	end
	return tostring(v)
end

local function field_control(L: { [string]: string }, scope: string, f: schema.Field, v: any): any
	if f.kind == "bool" then
		return { k = "switch", on = v == true }
	elseif f.kind == "number" then
		return { k = "number", value = v, min = f.min, max = f.max, step = f.step, unit = f.unit }
	elseif f.kind == "color" then
		return { k = "choice", value = v, options = color_options(L, f.options or schema.PALETTE_ORDER, v), style = "menu" }
	end
	local opts = {}
	for _, o in f.options or ({} :: { string }) do
		table.insert(opts, { value = o, label = i18n.option(L, scope, f.key, o) })
	end
	return { k = "choice", value = v, options = opts, style = f.style }
end

-- Bir alanın satırı (ya da satırları: profil renkleri her profil için bir satır).
local function field_rows(L: { [string]: string }, m: schema.Mod, f: schema.Field, s: schema.Settings, d: Data): { any }
	local id = `set.{m.id}.{f.key}`
	local v = s[f.key]
	local def = m.defaults[f.key]
	if f.kind == "colors" then
		local rows: { any } = {}
		local names: { string } = { "auto", "none" }
		for _, n in schema.PALETTE_ORDER do
			table.insert(names, n)
		end
		for _, profile in d.profiles do
			local cur = v[profile] or "auto"
			table.insert(rows, {
				id = `{id}.{profile}`,
				label = string.format(L.profile_color, profile),
				hint = L[`{m.id}.{f.key}.hint`],
				changed = cur ~= "auto" or nil,
				defaultLabel = L["color.auto"],
				control = { k = "choice", value = cur, options = color_options(L, names, cur), style = "menu" },
			})
		end
		if #rows == 0 then
			table.insert(rows, { id = id, label = L.profile_none, control = { k = "action", label = "—", act = "noop" }, disabled = L.profile_none })
		end
		return rows
	elseif f.kind == "path" then
		local hint = if v ~= "" then v else L.image_none
		if d.image_note then
			hint = hint .. " · " .. d.image_note
		end
		return {
			{
				id = id,
				label = L[`{m.id}.{f.key}`] or f.key,
				hint = hint,
				changed = v ~= def or nil,
				control = { k = "action", label = L.image_pick, act = `pick={m.id}.{f.key}` },
			},
		}
	end
	return {
		{
			id = id,
			label = L[`{m.id}.{f.key}`] or f.key,
			hint = L[`{m.id}.{f.key}.hint`],
			changed = v ~= def or nil,
			defaultLabel = shown(L, m.id, f, def),
			control = field_control(L, m.id, f, v),
		},
	}
end

local function look_page(L: { [string]: string }, d: Data): { any }
	local look_rows = {}
	for _, f in appearance.fields do
		local v = d.look[f.key]
		local def = appearance.defaults[f.key]
		local control
		if f.kind == "color" then
			control = { k = "choice", value = v, options = color_options(L, f.options or {}, v), style = "menu" }
		else
			control = field_control(L, "look", f, v)
		end
		table.insert(look_rows, {
			id = "look." .. f.key,
			label = L["look." .. f.key],
			hint = L[`look.{f.key}.hint`],
			changed = v ~= def or nil,
			defaultLabel = if f.kind == "color" then L["color." .. def] else i18n.option(L, "look", f.key, def),
			control = control,
		})
	end
	local presets = {}
	for _, name in appearance.PRESET_ORDER do
		table.insert(presets, {
			id = "preset." .. name,
			label = L["preset." .. name],
			hint = L[`preset.{name}.hint`],
			control = { k = "action", label = L.preset_apply, act = "preset=" .. name },
		})
	end
	table.insert(presets, { id = "alloff", label = L.all_off, hint = L.all_off_hint, control = { k = "action", label = L.all_off_btn, act = "alloff" } })
	return {
		{
			id = "language",
			title = L.sec_language,
			rows = {
				{
					id = "lang",
					label = L.lang,
					control = {
						k = "choice",
						value = d.lang,
						style = "segmented",
						options = { { value = "tr", label = "Türkçe" }, { value = "en", label = "English" } },
					},
				},
			},
		},
		{ id = "look", title = L.sec_look, rows = look_rows },
		{ id = "presets", title = L.sec_presets, rows = presets },
	}
end

local function mods_page(L: { [string]: string }, d: Data): { any }
	local sections = {}
	for _, m in registry.BUILTIN do
		local s = registry.settings(m, d.cfg)
		local rows: { any } = {
			{ id = "on." .. m.id, label = L.on, hint = L[m.id .. ".desc"], control = { k = "switch", on = d.on[m.id] == true } },
		}
		for _, f in m.fields do
			for _, r in field_rows(L, m, f, s, d) do
				table.insert(rows, r)
			end
		end
		table.insert(sections, { id = m.id, title = L[m.id .. ".title"] or m.id, rows = rows })
	end
	local user_rows: { any } = {}
	for _, u in d.user do
		table.insert(user_rows, {
			id = "on." .. u.id,
			label = u.title,
			hint = u.file .. " · " .. L.user_hint,
			control = { k = "switch", on = d.on[u.id] == true },
		})
	end
	table.insert(user_rows, {
		id = "folder",
		label = L.user_folder,
		hint = if #d.user == 0 then d.user_dir .. " · " .. L.user_none else d.user_dir,
		control = { k = "action", label = L.user_open, act = "folder" },
	})
	table.insert(sections, { id = "user", title = L.sec_user, rows = user_rows })
	return sections
end

local function count(t: { [string]: boolean }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

--- `prefs` düğümünün özellikleri. `page`: "look" ya da "mods"; `editing`: açık menü.
function panel.props(d: Data, page: string, editing: any): { [string]: any }
	local L = i18n.strings(d.lang)
	local on_page = if page == "mods" then "mods" else "look"
	local enabled = count(d.on)
	return {
		title = L.title,
		pages = {
			{ id = "look", label = L.page_look, icon = "sliders" },
			{ id = "mods", label = L.page_mods, icon = "puzzle", changed = if enabled > 0 then enabled else nil },
		},
		page = on_page,
		lead = if on_page == "mods" then L.lead_mods else L.lead_look,
		sections = if on_page == "mods" then mods_page(L, d) else look_page(L, d),
		editing = editing,
	}
end

local function with(t: any, key: string, value: any): { [string]: any }
	-- kv'den gelen tablolar korumalı olabilir (table.clone olmaz): elle kopyala.
	local out: { [string]: any } = {}
	if type(t) == "table" then
		for k, v in t do
			out[k] = v
		end
	end
	out[key] = value
	return out
end

--- Bir satırın yeni değeri (`value`, nil: varsayılana dön) için kv yazımları;
--- geçersiz değer ya da bilinmeyen satır boş liste.
function panel.change(d: Data, item: string, value: any): { Write }
	if item == "lang" then
		if value == "tr" or value == "en" then
			return { { key = i18n.KV_KEY, value = value } }
		end
		return {}
	end
	local look_key = string.match(item, "^look%.(.+)$")
	if look_key then
		if value == nil then
			return { { key = registry.KEY_LOOK, value = with(d.look, look_key, appearance.defaults[look_key]) } }
		end
		local v = appearance.accept(look_key, value)
		if v == nil then
			return {}
		end
		return { { key = registry.KEY_LOOK, value = with(d.look, look_key, v) } }
	end
	local on_id = string.match(item, "^on%.(.+)$")
	if on_id then
		local known = registry.builtin(on_id) ~= nil
		for _, u in d.user do
			known = known or u.id == on_id
		end
		if not known then
			return {}
		end
		return { { key = registry.KEY_ON, value = with(d.on, on_id, if value == true then true else nil) } }
	end
	local mod_id, rest = string.match(item, "^set%.([%w%-]+)%.(.+)$")
	local m = if mod_id then registry.builtin(mod_id) else nil
	if m == nil or rest == nil then
		return {}
	end
	local cfg = if type(d.cfg) == "table" then d.cfg else {}
	local current = registry.settings(m, cfg)
	local key, profile = string.match(rest, "^(%w+)%.(.+)$")
	if key and profile then
		-- Profil rengi: "auto" ya da nil rengi siler (ada göre otomatik).
		local f = schema.field(m.fields, key)
		if f == nil or f.kind ~= "colors" or not schema.is_profile_name(profile) then
			return {}
		end
		local colors: { [string]: string } = {}
		for k, c in current[key] do
			colors[k] = c
		end
		if value == nil or value == "auto" then
			colors[profile] = nil
		elseif value == "none" or schema.color(value) then
			colors[profile] = value
		else
			return {}
		end
		return { { key = registry.KEY_CFG, value = with(cfg, m.id, with(current, key, colors)) } }
	end
	local f = schema.field(m.fields, rest)
	if f == nil then
		return {}
	end
	local v
	if value == nil then
		v = m.defaults[rest]
	else
		v = schema.accept(f, value)
		if v == nil then
			return {}
		end
	end
	return { { key = registry.KEY_CFG, value = with(cfg, m.id, with(current, rest, v)) } }
end

--- Hazır set: açık modlar listedekilerle değişir (kullanıcı modları kapanır).
function panel.preset(name: string): { Write }?
	local ids = appearance.PRESETS[name]
	if ids == nil then
		return nil
	end
	local on: { [string]: boolean } = {}
	for _, id in ids do
		on[id] = true
	end
	return { { key = registry.KEY_ON, value = on } }
end

return panel
