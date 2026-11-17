--!strict
-- Pure logic of the bridge: job validation, the spool leader election, the Carly context line,
-- device and tab matching. No `tern` access here, so `lune` tests run it as is.

local bridge = {}

export type Job = {
	v: number,
	id: string,
	kind: string,
	from: string?,
	-- carly / notify
	text: string?,
	-- notify
	level: string?,
	title: string?,
	-- omp
	prompt: string?,
	cwd: string?,
	command: string?,
	how: string?,
	-- esp_open
	device: string?,
}

export type Device = {
	id: string,
	name: string,
	thread_id: number?,
	session_key: string?,
	session_id: string?,
	platform: string?,
}

bridge.VERSION = 1
bridge.KINDS = { carly = true, omp = true, esp_open = true, notify = true }
bridge.LEVELS = { info = true, success = true, error = true }
bridge.HOWS = { tab = true, split = true, replace_if_alone = true }
bridge.CONTEXT_MAX = 400

local LIMITS = { text = 8000, prompt = 32000, device = 200, cwd = 1024, command = 1024, title = 120, from = 64 }

local function str(v: any, field: string): (string?, string?)
	if v == nil then
		return nil, nil
	end
	if type(v) ~= "string" then
		return nil, `{field} must be a string`
	end
	local limit = LIMITS[field]
	if limit and #v > limit then
		return nil, `{field} is longer than {limit} bytes`
	end
	return v, nil
end

local function blank(s: string?): boolean
	return s == nil or string.match(s, "^%s*$") ~= nil
end

--- A spool job as `tern-bridge` writes it, checked and normalized; nil and the reason when it is not one.
function bridge.validate(raw: any): (Job?, string?)
	if type(raw) ~= "table" then
		return nil, "job is not a JSON object"
	end
	if raw.v ~= bridge.VERSION then
		return nil, `unsupported job version {tostring(raw.v)}`
	end
	local kind = raw.kind
	if type(kind) ~= "string" or not bridge.KINDS[kind] then
		return nil, `unknown kind {tostring(kind)}`
	end
	if type(raw.id) ~= "string" or blank(raw.id) then
		return nil, "job has no id"
	end
	local job: Job = { v = raw.v, id = raw.id, kind = kind }
	for _, field in { "from", "text", "level", "title", "prompt", "cwd", "command", "how", "device" } do
		local value, err = str(raw[field], field)
		if err then
			return nil, err
		end
		if not blank(value) then
			(job :: any)[field] = value
		end
	end
	if kind == "carly" and job.text == nil then
		return nil, "carly job needs text"
	elseif kind == "notify" then
		if job.text == nil then
			return nil, "notify job needs text"
		end
		job.level = job.level or "info"
		if not bridge.LEVELS[job.level :: string] then
			return nil, `unknown level {job.level}`
		end
	elseif kind == "omp" then
		if job.prompt == nil then
			return nil, "omp job needs a prompt"
		end
		job.how = job.how or "tab"
		if not bridge.HOWS[job.how :: string] then
			return nil, `unknown how {job.how}`
		end
	elseif kind == "esp_open" and job.device == nil then
		return nil, "esp_open job needs a device"
	end
	return job, nil
end

--- Whether a spool directory entry is a finished job file (`tern-bridge` writes `.tmp` files, then renames).
function bridge.is_job_file(name: string): boolean
	return string.sub(name, 1, 1) ~= "." and string.sub(name, -5) == ".json"
end

--- The oldest names past the newest `keep` (names sort by creation time).
function bridge.prune(names: { string }, keep: number): { string }
	local jobs: { string } = {}
	for _, name in names do
		if bridge.is_job_file(name) then
			table.insert(jobs, name)
		end
	end
	table.sort(jobs)
	local out: { string } = {}
	for i = 1, #jobs - keep do
		table.insert(out, jobs[i])
	end
	return out
end

--- One window consumes the spool: the one holding a fresh `leader` entry. Returns whether `me` leads and
--- whether it should write its heartbeat (a fresh entry of its own is left alone until `beat` s old).
function bridge.leader(entry: any, me: string, now: number, stale: number, beat: number): (boolean, boolean)
	local valid = type(entry) == "table" and type(entry.key) == "string" and type(entry.at) == "number"
	if valid and entry.key ~= me and now - entry.at < stale then
		return false, false
	end
	if valid and entry.key == me and now - entry.at < beat then
		return true, false
	end
	return true, true
end

--- Cuts `s` to at most `max` bytes on a UTF-8 boundary, ending in "…" when cut.
function bridge.clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	local cut = max - 3
	while cut > 0 do
		local b = string.byte(s, cut + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(s, 1, cut) .. "…"
end

--- The reason in a failed run's output: its last line saying "error", else its last non-blank line; trimmed.
function bridge.last_line(s: string): string
	local last, err = s, nil
	for line in string.gmatch(s, "[^\r\n]+") do
		if string.match(line, "%S") then
			last = line
			if string.find(string.lower(line), "error", 1, true) then
				err = line
			end
		end
	end
	return (string.match(err or last, "^%s*(.-)%s*$") :: string)
end

--- The Carly context line: gateway and messaging state from `gateway_state.json`, then the ESP devices.
function bridge.status_line(gw: any, devices: { Device }?, dev_err: string?): string
	local parts: { string } = {}
	if type(gw) == "table" then
		local platforms: { string } = {}
		if type(gw.platforms) == "table" then
			local names: { string } = {}
			for name in gw.platforms do
				if type(name) == "string" then
					table.insert(names, name)
				end
			end
			table.sort(names)
			for _, name in names do
				local p = gw.platforms[name]
				local state = if type(p) == "table" and type(p.state) == "string" then p.state else "?"
				local mark = if state == "connected" then "ok" else state
				table.insert(platforms, `{name} {mark}`)
			end
		end
		local state = if type(gw.gateway_state) == "string" then gw.gateway_state else "unknown"
		local line = `Hermes gateway {state}`
		if #platforms > 0 then
			line ..= ` ({table.concat(platforms, ", ")})`
		end
		table.insert(parts, line)
	else
		table.insert(parts, "Hermes gateway: no state file")
	end
	if devices then
		local list: { string } = {}
		for _, d in devices do
			local live = if type(d.session_id) == "string" then "" else ", no session"
			table.insert(list, `{d.name} [{d.id}{live}]`)
		end
		table.insert(parts, `ESP devices ({#devices}): {if #list > 0 then table.concat(list, "; ") else "none"}`)
	elseif dev_err then
		table.insert(parts, `ESP devices unknown ({dev_err})`)
	end
	table.insert(parts, "Use plugins['hermes-bridge'] esp_open/hermes_ask/hermes_kanban.")
	return bridge.clip(table.concat(parts, ". "), bridge.CONTEXT_MAX)
end

--- Devices from `hermes tern --list-devices` output; nil and the reason when it is not the C1 array.
function bridge.parse_devices(raw: any): ({ Device }?, string?)
	if type(raw) ~= "table" then
		return nil, "device list is not a JSON array"
	end
	local out: { Device } = {}
	for _, d in raw do
		if type(d) == "table" and type(d.id) == "string" then
			table.insert(out, {
				id = d.id,
				name = if type(d.name) == "string" then d.name else d.id,
				thread_id = if type(d.thread_id) == "number" then d.thread_id else nil,
				session_key = if type(d.session_key) == "string" then d.session_key else nil,
				session_id = if type(d.session_id) == "string" then d.session_id else nil,
				platform = if type(d.platform) == "string" then d.platform else nil,
			})
		end
	end
	return out, nil
end

--- The device `query` names: its id, then its name ignoring case, then the one device whose name contains it.
function bridge.match_device(devices: { Device }?, query: string): Device?
	if not devices then
		return nil
	end
	local q = string.lower(query)
	for _, d in devices do
		if string.lower(d.id) == q then
			return d
		end
	end
	for _, d in devices do
		if string.lower(d.name) == q then
			return d
		end
	end
	local hit: Device? = nil
	for _, d in devices do
		if string.find(string.lower(d.name), q, 1, true) then
			if hit then
				return nil
			end
			hit = d
		end
	end
	return hit
end

--- The tab of session `session` showing the device: named after it, or naming its id.
function bridge.find_tab(tabs: { any }, session: number, id: string, name: string): any?
	local lname, lid = string.lower(name), string.lower(id)
	for _, tab in tabs do
		if tab.session == session then
			local tname = string.lower(if type(tab.name) == "string" then tab.name else "")
			local title = string.lower(if type(tab.title) == "string" then tab.title else "")
			if tname == lname or string.find(tname, lid, 1, true) or string.find(title, lid, 1, true) then
				return tab
			end
		end
	end
	return nil
end

--- The shell command of a device tab (C1).
function bridge.device_command(id: string): string
	if string.match(id, "^[%w%-_%.]+$") then
		return `hermes tern --device {id}`
	end
	return `hermes tern --device "{string.gsub(id, '"', "")}"`
end

--- `cx.agents:list()` cut down for Carly.
function bridge.compact_agents(list: { any }): { any }
	local out = {}
	for _, a in list do
		table.insert(out, {
			pane = a.pane,
			command = if type(a.command) == "string" then a.command else nil,
			cwd = a.cwd,
			state = a.state,
			last_message = if type(a.last_message) == "string" then bridge.clip(a.last_message, 300) else nil,
		})
	end
	return out
end

--- Export calls get their positional args, then a fresh cx and the ExportCall: splits them, so optional
--- args left out don't shift cx into their place.
function bridge.split_args(...: any): ({ any }, any, any)
	local n = select("#", ...)
	local all = { ... }
	local args = {}
	for i = 1, n - 2 do
		args[i] = all[i]
	end
	return args, all[n - 1], all[n]
end

--- A profile name safe to pass to `hermes -p`.
function bridge.valid_profile(name: any): boolean
	return type(name) == "string" and string.match(name, "^[%w_%-]+$") ~= nil
end

return bridge
