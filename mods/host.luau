--!strict
-- Host half: the `panel` block (the tabbed Appearance and Mods settings page) and
-- converting an animated GIF/WebP into a sprite sheet with ffmpeg for the wallpaper.
-- Settings are written to kv; the window half watches kv and applies the CSS.

local strings = require("./lib/strings")
local panel = require("./lib/panel")
local registry = require("./lib/registry")
local appearance = require("./lib/appearance")
local sprite = require("./lib/sprite")

local ui = tern.ui

local DATA = tern.plugin.data
local USER_DIR = DATA .. "/" .. registry.USER_DIR
local ANIM_DIR = DATA .. "/wallpaper"
local POLL_MS = 1000

pcall(tern.fs.mkdir, USER_DIR)

local function home(): string?
	return tern.getenv("USERPROFILE") or tern.getenv("HOME")
end

-- omp profiles: `~/.omp/agent` counts as default, plus `~/.omp/profiles/*`.
local function profiles(): { string }
	local out: { string } = {}
	local h = home()
	if h == nil then
		return out
	end
	if tern.fs.exists(h .. "/.omp/agent") then
		table.insert(out, "default")
	end
	local ok, names = pcall(tern.fs.list, h .. "/.omp/profiles")
	if ok then
		for _, n in names do
			if n ~= "default" and tern.fs.exists(`{h}/.omp/profiles/{n}`) and string.match(n, "^[%w%._%-]+$") then
				table.insert(out, n)
			end
		end
	end
	return out
end

local function read_head(file: string): string?
	local ok, text = pcall(tern.fs.read, USER_DIR .. "/" .. file, registry.USER_MAX_BYTES)
	return if ok then string.sub(text, 1, 512) else nil
end

local function user_mods(): { registry.UserMod }
	local ok, files = pcall(tern.fs.list, USER_DIR)
	return registry.user_mods(if ok then files else {}, read_head)
end

-- Note under the wallpaper's image row: preparing, frame count, or an error.
local function image_note(L: { [string]: string }): string?
	local a = tern.kv.get("wp_anim")
	local cfg = registry.settings(registry.builtin("wallpaper") :: any, tern.kv.get(registry.KEY_CFG))
	if type(a) ~= "table" or a.src ~= cfg.image or cfg.image == "" then
		return nil
	end
	if a.error then
		return L.image_err .. ": " .. tostring(a.error)
	elseif a.busy then
		return L.image_busy
	elseif a.frames then
		return string.format(L.image_anim, a.frames, a.fps)
	end
	return nil
end

local function data(): panel.Data
	return {
		on = registry.enabled(tern.kv.get(registry.KEY_ON)),
		cfg = tern.kv.get(registry.KEY_CFG),
		look = appearance.normalize(tern.kv.get(registry.KEY_LOOK)),
		user = user_mods(),
		user_dir = USER_DIR,
		profiles = profiles(),
		image_note = image_note(strings.text),
	}
end

-- Everything about the panel that can change from outside (palette commands, other
-- windows, the user folder, the sprite conversion): the panel redraws when it changes.
local function signature(): string
	local ok, files = pcall(tern.fs.list, USER_DIR)
	return tern.json.encode({
		tern.kv.get(registry.KEY_ON),
		tern.kv.get(registry.KEY_CFG),
		tern.kv.get(registry.KEY_LOOK),
		tern.kv.get("wp_anim"),
		if ok then files else nil,
	})
end

local function write(ws: { panel.Write })
	for _, w in ws do
		tern.kv.set(w.key, w.value)
	end
end

type State = {
	page: string,
	editing: any,
	closed: boolean,
	last: string,
}

tern.block.define("panel", {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local s: State = {
			page = if type(saved) == "table" and saved.page == "mods" then "mods" else "look",
			editing = nil,
			closed = false,
			last = signature(),
		}
		local function poll()
			if s.closed then
				return
			end
			local now = signature()
			if now ~= s.last then
				s.last = now
				-- A pane closed with Tern's own × button has no close hook: rendering fails and the chain ends.
				if not pcall(cx.render, cx) then
					return
				end
			end
			tern.timer(POLL_MS, poll)
		end
		tern.timer(POLL_MS, poll)
		return s
	end,
	title = function(_s: State): string?
		return strings.text.title
	end,
	view = function(s: State, _cx: BlockCx): BlockView
		return { main = ui.col({ ui.node("prefs", panel.props(data(), s.page, s.editing)) }) }
	end,
	save = function(s: State): any
		return { page = s.page }
	end,
	event = function(s: State, ev: UiEvent, cx: BlockCx)
		local d = data()
		if ev.ev == "action" then
			local act, value = ev.act, ev.value
			if act == "page" and (value == "look" or value == "mods") then
				s.page = value
				s.editing = nil
			elseif act == "close" then
				if value == nil then
					s.closed = true
					cx:exit(0)
				else
					s.editing = nil
				end
			elseif act == "preset" and type(value) == "string" then
				local ws = panel.preset(value)
				if ws then
					write(ws)
				end
			elseif act == "alloff" then
				tern.kv.set(registry.KEY_ON, {})
			elseif act == "folder" then
				pcall(tern.fs.mkdir, USER_DIR)
				cx:open(USER_DIR)
			elseif act == "pick" and type(value) == "string" then
				-- The path prompt (cx:prompt) exists only in the window half; the window watches this request.
				tern.kv.set("pick_req", { id = string.format("%.3f", tern.now()), field = value })
			end
			return
		end
		if ev.ev == "activate" and type(ev.item) == "string" then
			-- Menu opened: the selected option is kept as a preview.
			s.editing = { row = ev.item }
			return
		end
		if ev.ev == "select" and type(ev.item) == "string" then
			local row, option = string.match(ev.item, "^(.-)=(.*)$")
			if row and s.editing and s.editing.row == row then
				s.editing = { row = row, option = option }
			end
			return
		end
		if ev.ev == "change" and type(ev.item) == "string" then
			s.editing = nil
			write(panel.change(d, ev.item, ev.value))
		end
	end,
	key = function(s: State, k: Key, cx: BlockCx): boolean?
		if k.name == "escape" then
			if s.editing then
				s.editing = nil
				return true
			end
			s.closed = true
			cx:exit(0)
			return true
		end
		return false
	end,
})

-- Animated wallpaper ---------------------------------------------------------
--
-- The `wp_anim` record: { src, busy } while converting, { src, file, cols, rows,
-- frames, fps, ratio } when done, { src, still = true } for a single frame, { src,
-- error } on failure. The window uses it while `src` matches the selected image.

local converting: string? = nil

local function is_animated_ext(path: string): boolean
	local ext = string.lower(string.match(path, "%.(%w+)$") or "")
	return ext == "gif" or ext == "webp" or ext == "apng"
end

local function finish(src: string, rec: { [string]: any })
	rec.src = src
	tern.kv.set("wp_anim", rec)
	converting = nil
end

local function convert(src: string)
	converting = src
	tern.kv.set("wp_anim", { src = src, busy = true })
	local probe = {
		"ffprobe",
		"-v",
		"error",
		"-select_streams",
		"v:0",
		"-count_packets",
		"-show_entries",
		"stream=width,height,nb_read_packets,avg_frame_rate,r_frame_rate:format=duration",
		"-of",
		"json",
		src,
	}
	local ok = pcall(tern.process.run, probe, { timeout_ms = 30000 }, function(r: ProcessResult)
		if r.status ~= 0 then
			finish(src, { error = "ffprobe: " .. string.sub(r.stderr, 1, 160) })
			return
		end
		local okj, info = pcall(tern.json.decode, r.stdout)
		local st = okj and type(info) == "table" and type(info.streams) == "table" and info.streams[1]
		if not st then
			finish(src, { error = "ffprobe: no video stream" })
			return
		end
		local frames_in = tonumber(st.nb_read_packets)
		local duration = tonumber(info.format and info.format.duration)
		local fps_in = sprite.rate(st.avg_frame_rate) or sprite.rate(st.r_frame_rate)
		local plan = if frames_in and frames_in > 1
			then sprite.plan(tonumber(st.width) or 0, tonumber(st.height) or 0, duration, fps_in, frames_in)
			else nil
		if plan == nil then
			finish(src, { still = true })
			return
		end
		pcall(tern.fs.mkdir, ANIM_DIR)
		local out = `{ANIM_DIR}/anim-{string.sub(tern.sha256(src), 1, 12)}.jpg`
		local vf = string.format(
			"fps=%d,trim=end_frame=%d,scale=%d:%d:flags=lanczos,tile=%dx%d",
			plan.fps,
			plan.frames,
			plan.w,
			plan.h,
			plan.cols,
			plan.rows
		)
		local argv = { "ffmpeg", "-v", "error", "-y", "-i", src, "-vf", vf, "-frames:v", "1", "-q:v", "4", out }
		local started = pcall(tern.process.run, argv, { timeout_ms = 120000 }, function(r2: ProcessResult)
			if r2.status ~= 0 or not tern.fs.exists(out) then
				finish(src, { error = "ffmpeg: " .. string.sub(r2.stderr, 1, 160) })
				return
			end
			finish(src, {
				file = out,
				cols = plan.cols,
				rows = plan.rows,
				frames = plan.frames,
				fps = plan.fps,
				ratio = plan.w / plan.h,
			})
		end)
		if not started then
			finish(src, { still = true, error = "ffmpeg not found" })
		end
	end)
	if not ok then
		-- Without ffmpeg the image is still shown, with its first frame only.
		finish(src, { still = true, error = "ffprobe not found" })
	end
end

local function watch_wallpaper()
	local on = registry.enabled(tern.kv.get(registry.KEY_ON))
	local m = registry.builtin("wallpaper")
	if on.wallpaper and m then
		local s = registry.settings(m, tern.kv.get(registry.KEY_CFG))
		local src: string = s.image
		local rec = tern.kv.get("wp_anim")
		local done = type(rec) == "table" and rec.src == src and not rec.busy
		local file_gone = done and rec.file ~= nil and not tern.fs.exists(rec.file)
		if s.source == "image" and src ~= "" and is_animated_ext(src) and converting ~= src then
			if (not done or file_gone) and tern.fs.exists(src) then
				convert(src)
			end
		end
	end
	tern.timer(POLL_MS, watch_wallpaper)
end
-- A conversion left half-done by a reload (`busy`) starts over.
do
	local rec = tern.kv.get("wp_anim")
	if type(rec) == "table" and rec.busy then
		tern.kv.set("wp_anim", nil)
	end
end
tern.timer(POLL_MS, watch_wallpaper)
