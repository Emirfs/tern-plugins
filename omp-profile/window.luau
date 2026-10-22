--!strict
-- omp profil: odaktaki pane'de çalışan omp oturumunun profilini durum
-- satırında ve sekme başlığında gösterir.
--
-- omp, Tern'e oturum dosyasını bildirir (OSC 1337 `omp_session_file`);
-- `tern inspect --json` bunu pane başına verir. Profil dosyanın yolundan
-- okunur: `~/.omp/profiles/<ad>/…` → <ad>, `~/.omp/agent/…` → default.

-- Pane id → profil adı; omp çalışmayan pane'ler yok.
local profiles: { [number]: string } = {}

local inflight = false
local queued = false
local debounce: TimerHandle? = nil
local last_title_refresh = -math.huge

-- Odak ve pane olayları kısa bir beklemeyle, başlık olayları (omp çalışırken
-- başlığı sürekli günceller) en fazla bu sıklıkta yenileme tetikler.
local DEBOUNCE_MS = 250
local TITLE_MIN_MS = 5000
-- Olay kaçarsa diye arka plan yenilemesi.
local POLL_MS = 30000

local TONES = { "accent", "info", "success", "warning", "pending", "user" }

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

-- Profil adından sabit bir renk: aynı profil her yerde aynı renkte.
local function tone_of(name: string): string
	if name == "default" then
		return "muted"
	end
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 2147483647
	end
	return TONES[h % #TONES + 1]
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

local refresh: () -> ()

local function apply(stdout: string)
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(data.panes) ~= "table" then
		return
	end
	local next_map: { [number]: string } = {}
	for _, p in data.panes do
		local name = profile_of(p.omp_session_file)
		if name and type(p.pane) == "number" then
			next_map[p.pane] = name
		end
	end
	local changed = false
	for k, v in next_map do
		if profiles[k] ~= v then
			changed = true
		end
	end
	for k in profiles do
		if next_map[k] == nil then
			changed = true
		end
	end
	profiles = next_map
	if changed then
		tern.chrome.refresh()
	end
end

refresh = function()
	if inflight then
		queued = true
		return
	end
	inflight = true
	local ok = pcall(function()
		tern.process.run(tern_argv(), { timeout_ms = 10000 }, function(r, _)
			inflight = false
			if r.status == 0 then
				apply(r.stdout)
			end
			if queued then
				queued = false
				refresh()
			end
		end)
	end)
	if not ok then
		inflight = false
	end
end

local function soon()
	if debounce then
		debounce:cancel()
	end
	debounce = tern.timer(DEBOUNCE_MS, function()
		debounce = nil
		refresh()
	end)
end

local function poll()
	tern.timer(POLL_MS, function()
		refresh()
		poll()
	end)
end

-- Eklenti açık bir pencereye sonradan yüklenince window_start gelmez: yüklenirken de başla.
refresh()
poll()
tern.on("window_start", function(_cx)
	refresh()
end)
tern.on("focus", function(_ev, _cx)
	soon()
end)
tern.on("pane_created", function(_ev, _cx)
	soon()
end)
tern.on("pane_closed", function(ev, _cx)
	profiles[ev.pane] = nil
	tern.chrome.refresh()
end)
tern.on("title", function(_ev, _cx)
	local now = tern.now()
	if now - last_title_refresh >= TITLE_MIN_MS then
		last_title_refresh = now
		soon()
	end
end)

tern.chrome.status(function(pane)
	local name = profiles[pane.pane]
	if name == nil then
		return nil
	end
	return { { text = "omp: " .. name, icon = "sparkle", tone = tone_of(name) } }
end)

tern.chrome.tab_title(function(tab)
	local name = profiles[tab.pane]
	if name == nil then
		return nil
	end
	local base = if tab.name and tab.name ~= "" then tab.name else tab.title
	return "[" .. name .. "] " .. base
end)
