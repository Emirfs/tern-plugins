--!strict
-- host.luau'yu Tern olmadan çalıştırmak için çalışma zamanı taklidi: düğümler
-- düz tablo, süreçler tutulur ve test bitirir, kv bellekte, dosya sistemi
-- verilen yol kümesi. Windows gibi davranır (ev dizini `C:\home`).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local stub = {}

export type Proc = { argv: { string }, env: { [string]: string }, done: (any) -> () }

export type Harness = {
	blocks: { [string]: any },
	kv: { [string]: any },
	procs: { Proc },
	-- `tern.fs.exists`'e sorulan yollar.
	probed: { string },
	-- Bu adlarla başlatma hata fırlatır (PATH'te yok gibi).
	missing: { [string]: boolean },
	renders: number,
	cx: any,
	-- Bekleyen süreci bitirir: stdout JSON'a çevrilen değer ya da hata.
	finish: (proc: Proc, result: { data: any?, status: number?, stderr: string?, timed_out: boolean? }) -> (),
}

local HOME = "C:\\home"

local function nodes(): any
	local ui: { [string]: any } = {}
	for _, kind in { "text", "col", "row", "rule", "table", "list", "progress", "md" } do
		ui[kind] = function(...: any): any
			return { k = kind, a = { ... } }
		end
	end
	ui.span = function(t: string, s: string?): any
		return { t = t, s = s }
	end
	ui.meter_cell = function(v: number): any
		return { k = "meter_cell", meter = { value = v } }
	end
	ui.node = function(kind: string, props: any): any
		return { k = kind, p = props }
	end
	return ui
end

--- Görünümdeki bütün metin, satır satır.
function stub.text(node: any): string
	local out: { string } = {}
	local function walk(n: any)
		if type(n) == "string" then
			table.insert(out, n)
		elseif type(n) == "table" then
			if type(n.t) == "string" then
				table.insert(out, n.t)
			end
			for k, v in n do
				if k ~= "t" and k ~= "s" then
					walk(v)
				end
			end
		end
	end
	walk(node)
	return table.concat(out, "\n")
end

--- `root` altındaki host.luau'yu taklitle yükler; `profiles` ~/.omp/profiles altındakiler.
function stub.host(root: string, profiles: { string }, existing: { string }?): Harness
	local h: Harness = {
		blocks = {},
		kv = {},
		procs = {},
		probed = {},
		missing = {},
		renders = 0,
		cx = nil,
		finish = function() end,
	}
	local exists: { [string]: boolean } = { [HOME .. "\\.omp\\agent"] = true }
	for _, name in profiles do
		exists[HOME .. "\\.omp\\profiles\\" .. name .. "\\agent"] = true
	end
	for _, path in existing or {} do
		exists[path] = true
	end

	local tern = {
		ui = nodes(),
		runtime = { os = "windows" },
		getenv = function(name: string): string?
			return if name == "USERPROFILE" then HOME else nil
		end,
		json = {
			decode = function(text: string): any
				return serde.decode("json", text)
			end,
		},
		kv = {
			get = function(key: string): any
				return h.kv[key]
			end,
			set = function(key: string, value: any)
				-- Tern gibi JSON'a çevirip geri okur: saklanan kopya, canlı tablo değil.
				h.kv[key] = if value == nil then nil else serde.decode("json", serde.encode("json", value))
			end,
		},
		fs = {
			exists = function(path: string): boolean
				table.insert(h.probed, path)
				return exists[path] == true
			end,
			list = function(path: string): { string }
				if path ~= HOME .. "\\.omp\\profiles" then
					error("no such directory: " .. path)
				end
				return table.clone(profiles)
			end,
		},
		process = {
			run = function(argv: { string }, opts: any, cb: (any, any) -> ())
				if h.missing[argv[1]] then
					error("program not found: " .. argv[1])
				end
				table.insert(h.procs, {
					argv = argv,
					env = opts.env,
					done = function(result: any)
						cb(result, nil)
					end,
				})
			end,
		},
		pane = {
			list = function(): { any }
				return { { pane = 1 } }
			end,
		},
		timer = function(_ms: number, _fn: () -> ()): any
			return { cancel = function() end }
		end,
		block = {
			define = function(id: string, def: any)
				h.blocks[id] = def
			end,
		},
	}

	h.cx = {
		pane = 1,
		cols = 120,
		rows = 80,
		render = function()
			h.renders += 1
		end,
	}

	h.finish = function(proc: Proc, result)
		proc.done({
			status = result.status or 0,
			stdout = if result.data ~= nil then serde.encode("json", result.data) else "",
			stderr = result.stderr or "",
			timed_out = result.timed_out == true,
		})
	end

	-- `require("./x")` isteyen dosyanın klasörüne göre çözülür.
	local cache: { [string]: any } = {}
	local function load(path: string): any
		if cache[path] ~= nil then
			return cache[path]
		end
		local dir = string.match(path, "^(.*)/[^/]+$") or "."
		local function req(rel: string): any
			local target = string.gsub(rel, "^%./", dir .. "/")
			return load(target .. ".luau")
		end
		local chunk = luau.load(luau.compile(fs.readFile(path)), { environment = { tern = tern, require = req } })
		local value = chunk()
		cache[path] = if value == nil then true else value
		return cache[path]
	end
	load(root .. "/host.luau")
	return h
end

return stub
