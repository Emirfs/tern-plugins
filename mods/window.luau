--!strict
-- Window half: applies the enabled mods with `tern.css("mod-<id>", …)` (a sheet name
-- takes only letters, digits, `_` and `-`; Tern makes it `plugin:local:mods:mod-<id>`) and
-- clears the disabled ones; Appearance settings go in the `look` sheet. kv is read twice a
-- second (Tern rereads the kv file only when it changes on disk, so a read is cheap); a sheet
-- is rebuilt only when its CSS changed. Also the palette commands, the focus mode
-- shortcut and the path prompt the panel asks for (cx:prompt exists only here).

local appearance = require("./lib/appearance")
local strings = require("./lib/strings")
local panel = require("./lib/panel")
local registry = require("./lib/registry")
local schema = require("./lib/schema")

local TICK_MS = 500
-- The user folder is scanned once every this many ticks.
local USER_SCAN_TICKS = 4
local PANEL_KIND = "mods.panel"
local FOCUS_KEY = "ctrl+alt+z"
local DATA = tern.plugin.data
local USER_DIR = DATA .. "/" .. registry.USER_DIR
local WALLPAPER_MAX_BYTES = 16 * 1024 * 1024

pcall(tern.fs.mkdir, USER_DIR)

local L = strings.text

-- Installed sheets: name → CSS ("" is empty).
local applied: { [string]: string } = {}

local function apply_sheet(name: string, css: string?)
	local text = css or ""
	if (applied[name] or "") ~= text then
		tern.css(name, text)
		applied[name] = text
	end
end

-- omp profiles --------------------------------------------------------------
-- Path of the omp-profile plugin: `tern inspect --json` gives each pane's omp session
-- file; `~/.omp/profiles/<name>/…` → <name>, `~/.omp/agent/…` → default.

local profiles: { [number]: string } = {}
local inspecting = false
local inspect_queued = false
local last_title_refresh = -math.huge
local PROFILE_POLL_MS = 30000
local TITLE_MIN_MS = 5000

local function profile_of(file: any): string?
	if type(file) ~= "string" then
		return nil
	end
	local norm = string.gsub(file, "\\", "/")
	local name = string.match(norm, "/%.omp/profiles/([^/]+)/")
	if name then
		return name
	end
	if string.find(norm, "/.omp/agent/", 1, true) then
		return "default"
	end
	return nil
end

local function tern_argv(): { string }
	if tern.runtime.os == "windows" then
		local base = tern.getenv("LOCALAPPDATA")
		if base then
			local com = base .. "\\Programs\\Tern\\tern.com"
			if tern.fs.exists(com) then
				return { com, "inspect", "--json" }
			end
		end
	end
	return { "tern", "inspect", "--json" }
end

local function accent_on(): boolean
	return registry.enabled(tern.kv.get(registry.KEY_ON))["profile-accent"] == true
end

local function inspect()
	if not accent_on() then
		return
	end
	if inspecting then
		inspect_queued = true
		return
	end
	inspecting = true
	local ok = pcall(tern.process.run, tern_argv(), { timeout_ms = 10000 }, function(r: ProcessResult)
		inspecting = false
		if r.status == 0 then
			local okj, d = pcall(tern.json.decode, r.stdout)
			if okj and type(d) == "table" and type(d.panes) == "table" then
				local map: { [number]: string } = {}
				for _, p in d.panes do
					local name = profile_of(p.omp_session_file)
					if name and type(p.pane) == "number" and schema.is_profile_name(name) then
						map[p.pane] = name
					end
				end
				profiles = map
			end
		end
		if inspect_queued then
			inspect_queued = false
			inspect()
		end
	end)
	if not ok then
		inspecting = false
	end
end

local function panes_env(cx: WindowCx?): { schema.PaneEnv }
	local out: { schema.PaneEnv } = {}
	if cx == nil or next(profiles) == nil then
		return out
	end
	local ok, panes = pcall(function()
		return cx.session:panes()
	end)
	if not ok then
		return out
	end
	for _, p in panes do
		local name = profiles[p.pane]
		if name then
			table.insert(out, { pane = p.pane, title = p.title or "", profile = name, focused = p.focused == true })
		end
	end
	return out
end

-- Wallpaper -----------------------------------------------------------------
-- The image's bytes become a `data:` URL; encoded once per file.

local wp_cache: { key: string, url: string }? = nil

local MIME: { [string]: string } = {
	png = "image/png",
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	gif = "image/gif",
	webp = "image/webp",
	bmp = "image/bmp",
	svg = "image/svg+xml",
	avif = "image/avif",
}

local function data_url(path: string): string?
	if wp_cache and wp_cache.key == path then
		return wp_cache.url
	end
	local ext = string.lower(string.match(path, "%.(%w+)$") or "")
	local mime = MIME[ext]
	if mime == nil then
		return nil
	end
	local ok, bytes = pcall(tern.fs.read, path, WALLPAPER_MAX_BYTES)
	if not ok then
		return nil
	end
	local url = `data:{mime};base64,{tern.base64.encode(bytes)}`
	wp_cache = { key = path, url = url }
	return url
end

local function wallpaper_env(s: schema.Settings, env: schema.Env)
	if s.source ~= "image" or s.image == "" then
		return
	end
	local rec = tern.kv.get("wp_anim")
	if type(rec) == "table" and rec.src == s.image and type(rec.file) == "string" then
		local url = data_url(rec.file)
		if url and type(rec.cols) == "number" and type(rec.rows) == "number" then
			env.wallpaper_anim = {
				url = url,
				cols = rec.cols,
				rows = rec.rows,
				frames = rec.frames,
				fps = rec.fps,
				ratio = rec.ratio,
			}
			return
		end
	end
	env.wallpaper_url = data_url(s.image)
end

-- Applying ------------------------------------------------------------------

local user_cache: { registry.UserMod } = {}
local ticks = 0

local function read_user(file: string): string?
	local ok, text = pcall(tern.fs.read, USER_DIR .. "/" .. file, registry.USER_MAX_BYTES)
	return if ok then text else nil
end

local function sync(cx: WindowCx?)
	local on = registry.enabled(tern.kv.get(registry.KEY_ON))
	local cfg = tern.kv.get(registry.KEY_CFG)
	apply_sheet("look", appearance.css(appearance.normalize(tern.kv.get(registry.KEY_LOOK))))

	for _, m in registry.BUILTIN do
		local css: string? = nil
		if on[m.id] then
			local s = registry.settings(m, cfg)
			local env: schema.Env = { panes = {} }
			if m.id == "profile-accent" then
				env.panes = panes_env(cx)
			elseif m.id == "wallpaper" then
				wallpaper_env(s, env)
			end
			local ok, out = pcall(m.css, s, env)
			css = if ok then out else nil
		end
		apply_sheet("mod-" .. m.id, css)
	end

	if ticks % USER_SCAN_TICKS == 0 then
		local ok, files = pcall(tern.fs.list, USER_DIR)
		user_cache = registry.user_mods(if ok then files else {}, read_user)
	end
	local seen: { [string]: boolean } = {}
	for _, u in user_cache do
		seen["mod-" .. u.id] = true
		apply_sheet("mod-" .. u.id, if on[u.id] then read_user(u.file) else nil)
	end
	-- A deleted user file's sheet goes away too.
	for name, text in applied do
		if string.sub(name, 1, 9) == "mod-user-" and not seen[name] and text ~= "" then
			apply_sheet(name, nil)
		end
	end
end

-- The panel's path request: Tern's path prompt opens and the entered path is written to the setting.
local handled_pick: string? = nil
do
	local req = tern.kv.get("pick_req")
	handled_pick = if type(req) == "table" then req.id else nil
end

local function check_pick(cx: WindowCx?)
	local req = tern.kv.get("pick_req")
	if cx == nil or type(req) ~= "table" or req.id == handled_pick or type(req.field) ~= "string" then
		return
	end
	handled_pick = req.id
	local mod_id, key = string.match(req.field, "^([%w%-]+)%.(%w+)$")
	local m = if mod_id then registry.builtin(mod_id) else nil
	if m == nil or key == nil then
		return
	end
	local cur = registry.settings(m, tern.kv.get(registry.KEY_CFG))[key]
	cx:prompt({ value = cur, placeholder = L.image_prompt, icon = "image" }):next(function(text: string?)
		if text == nil then
			return
		end
		-- Explorer's "Copy as path" gives a quoted path.
		local path = string.gsub(string.gsub(text, '^%s*"?', ""), '"?%s*$', "")
		local d: panel.Data = {
			on = {},
			cfg = tern.kv.get(registry.KEY_CFG),
			look = {},
			user = {},
			user_dir = USER_DIR,
			profiles = {},
		}
		for _, w in panel.change(d, `set.{m.id}.{key}`, path) do
			tern.kv.set(w.key, w.value)
		end
		-- Choosing an image also switches the source to image.
		if m.id == "wallpaper" and path ~= "" then
			d.cfg = tern.kv.get(registry.KEY_CFG)
			for _, w in panel.change(d, "set.wallpaper.source", "image") do
				tern.kv.set(w.key, w.value)
			end
		end
	end)
end

local function tick()
	tern.timer(TICK_MS, function(cx: WindowCx?)
		-- Schedule the next tick first: an error must not break the chain.
		tick()
		ticks += 1
		local ok, err = pcall(function()
			sync(cx)
		end)
		if not ok then
			tern.log.warn("mods: sync failed", err)
		end
		pcall(check_pick, cx)
	end)
end

local function poll_profiles()
	tern.timer(PROFILE_POLL_MS, function()
		inspect()
		poll_profiles()
	end)
end

-- When the plugin loads into an already open window, window_start never arrives: start on load too.
sync(nil)
inspect()
tick()
poll_profiles()

tern.on("window_start", function(cx: WindowCx)
	sync(cx)
	inspect()
end)
tern.on("focus", function(_ev: FocusEvent, _cx: WindowCx)
	inspect()
end)
tern.on("pane_created", function(_ev: PaneEvent, _cx: WindowCx)
	inspect()
end)
tern.on("pane_closed", function(ev: PaneEvent, _cx: WindowCx)
	profiles[ev.pane] = nil
end)
tern.on("title", function(_ev: any, _cx: WindowCx)
	local now = tern.now()
	if now - last_title_refresh >= TITLE_MIN_MS then
		last_title_refresh = now
		inspect()
	end
end)

-- Commands ------------------------------------------------------------------

local function is_panel(title: string): boolean
	return title == L.title
end

local function toggle(cx: WindowCx, id: string)
	local on = registry.enabled(tern.kv.get(registry.KEY_ON))
	local name = L[id .. ".title"] or id
	if on[id] then
		on[id] = nil
		cx:toast("info", string.format(L.toast_off, name))
	else
		on[id] = true
		cx:toast("info", string.format(L.toast_on, name))
	end
	tern.kv.set(registry.KEY_ON, on)
	sync(cx)
end

tern.command({
	id = "open",
	title = L.cmd_open,
	icon = "sliders",
	run = function(cx: WindowCx)
		for _, pane in cx.session:panes() do
			if (pane.block == PANEL_KIND or is_panel(pane.title or "")) and not pane.parked then
				cx.layout:focus(pane.pane)
				return
			end
		end
		if cx:new_block(PANEL_KIND, nil, "beside") == nil then
			cx:toast("error", L.not_loaded, L.not_loaded_detail)
		end
	end,
})

tern.command({
	id = "focus",
	title = L.cmd_focus,
	icon = "eye",
	keys = { FOCUS_KEY },
	run = function(cx: WindowCx)
		toggle(cx, "focus-mode")
	end,
})

tern.command({
	id = "privacy",
	title = L.cmd_privacy,
	icon = "eye",
	run = function(cx: WindowCx)
		toggle(cx, "privacy-blur")
	end,
})

tern.command({
	id = "folder",
	title = L.cmd_folder,
	icon = "sliders",
	run = function(cx: WindowCx)
		pcall(tern.fs.mkdir, USER_DIR)
		cx:open(USER_DIR)
	end,
})

tern.command({
	id = "off",
	title = L.cmd_off,
	icon = "sliders",
	run = function(cx: WindowCx)
		tern.kv.set(registry.KEY_ON, {})
		sync(cx)
		cx:toast("info", L.toast_all_off)
	end,
})
