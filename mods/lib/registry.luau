--!strict
-- The list of mods and their state in kv. Both halves read the same keys:
--   on   = { [mod id] = true }      enabled mods (built-in and user)
--   cfg  = { [mod id] = settings }  settings of the built-in mods
--   look = the Appearance tab's settings
-- User mods: `user-mods/*.css` in the data folder, ids `user-<name>`.

local schema = require("./schema")

local registry = {}

registry.BUILTIN = {
	require("./mods/compact_tabs"),
	require("./mods/tab_style"),
	require("./mods/profile_accent"),
	require("./mods/focus_mode"),
	require("./mods/privacy_blur"),
	require("./mods/pane_shape"),
	require("./mods/wallpaper"),
	require("./mods/composer"),
	require("./mods/ask_style"),
	require("./mods/busy_animation"),
} :: { schema.Mod }

registry.KEY_ON = "on"
registry.KEY_CFG = "cfg"
registry.KEY_LOOK = "look"
registry.USER_DIR = "user-mods"
-- The largest size read from a user CSS file.
registry.USER_MAX_BYTES = 256 * 1024

function registry.builtin(id: string): schema.Mod?
	for _, m in registry.BUILTIN do
		if m.id == id then
			return m
		end
	end
	return nil
end

--- The enabled mods from kv's `on` table; unrecognized values are dropped.
function registry.enabled(raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) ~= "table" then
		return out
	end
	for id, v in raw do
		if type(id) == "string" and v == true and string.match(id, "^[%w%-]+$") then
			out[id] = true
		end
	end
	return out
end

--- A built-in mod's validated settings from kv (`cfg[id]`).
function registry.settings(m: schema.Mod, cfg: any): schema.Settings
	local raw = if type(cfg) == "table" then cfg[m.id] else nil
	return schema.normalize(m.fields, m.defaults, raw)
end

export type UserMod = {
	id: string,
	file: string,
	title: string,
}

--- A mod id from a file name: `My Theme.css` → `user-my-theme`; nil if it isn't CSS.
function registry.user_id(file: string): string?
	local stem = string.match(file, "^(.+)%.[cC][sS][sS]$")
	if stem == nil then
		return nil
	end
	local slug = string.lower(stem)
	slug = string.gsub(slug, "[^%w]+", "-")
	slug = string.gsub(slug, "^%-+", "")
	slug = string.gsub(slug, "%-+$", "")
	if slug == "" then
		return nil
	end
	return "user-" .. string.sub(slug, 1, 40)
end

--- A title from the leading `/* title: … */` comment of the file, else the file name without extension.
function registry.user_title(text: string?, file: string): string
	if text then
		local head = string.match(text, "^%s*/%*(.-)%*/")
		local title = head and string.match(head, "^%s*[Tt]itle%s*:%s*([^\n]-)%s*$")
		if title == nil and head then
			title = string.match(head, "^%s*[Tt]itle%s*:%s*([^\n]-)%s*\n")
		end
		if title and title ~= "" then
			return title
		end
	end
	return (string.gsub(file, "%.[cC][sS][sS]$", ""))
end

--- User mods from a folder listing, sorted by name; a second file that lands on
--- the same id gets `-2`. `read(file)` gives the file's head (for the title).
function registry.user_mods(files: { string }, read: (file: string) -> string?): { UserMod }
	local out: { UserMod } = {}
	local seen: { [string]: boolean } = {}
	-- The tables Tern gives are protected (no table.clone): copy by hand.
	local sorted: { string } = {}
	for _, f in files do
		table.insert(sorted, f)
	end
	table.sort(sorted)
	for _, file in sorted do
		local id = registry.user_id(file)
		if id then
			local base, n = id, 1
			while seen[id] do
				n += 1
				id = base .. "-" .. n
			end
			seen[id] = true
			table.insert(out, { id = id, file = file, title = registry.user_title(read(file), file) })
		end
	end
	return out
end

return registry
