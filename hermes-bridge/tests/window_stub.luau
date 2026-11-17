--!strict
-- Runs window.luau without Tern: an in-memory file system and kv, recorded processes, timers fired on
-- demand, captured Carly exports and a fake window `cx` with sessions, tabs and agents. Windows paths.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local stub = {}

export type Proc = { argv: { string }, opts: any, done: (any, any) -> () }

local function parent(path: string): string
	return string.match(path, "^(.*)\\[^\\]+$") or ""
end

local function base(path: string): string
	return string.match(path, "([^\\]+)$") or path
end

function stub.new(root: string): any
	local h: any = {
		files = {} :: { [string]: string },
		dirs = {} :: { [string]: boolean },
		kv = {} :: { [string]: any },
		procs = {} :: { Proc },
		missing = {} :: { [string]: boolean },
		timers = {} :: { any },
		exports = {} :: { [string]: any },
		commands = {} :: { [string]: any },
		handlers = {} :: { [string]: any },
		context = nil :: any,
		env = {
			USERPROFILE = "C:\\home",
			LOCALAPPDATA = "C:\\lad",
			TERN_BRIDGE_SPOOL = "C:\\spool",
		} :: { [string]: string },
	}

	local tern: any = {
		context = "window",
		plugin = { id = "hermes-bridge", name = "Hermes köprüsü", dir = "C:\\plugin", data = "C:\\data" },
		runtime = { os = "windows", jit = false },
		getenv = function(name: string): string?
			return h.env[name]
		end,
		now = os.clock,
		log = {
			debug = function(...) end,
			info = function(...) end,
			warn = function(...) end,
			error = function(...) end,
		},
		json = {
			encode = function(v: any, _pretty: boolean?): string
				return serde.encode("json", v)
			end,
			decode = function(s: string): any
				return serde.decode("json", s)
			end,
			array = function(t: any?): any
				return t or {}
			end,
			null = nil,
		},
		kv = {
			get = function(k: string): any
				return h.kv[k]
			end,
			set = function(k: string, v: any)
				h.kv[k] = v
			end,
		},
		fs = {
			read = function(path: string, max: number?): string
				local text = h.files[path]
				if text == nil then
					error(`no such file {path}`)
				end
				if max and #text > max then
					error("too large")
				end
				return text
			end,
			write = function(path: string, text: string)
				if not h.dirs[parent(path)] then
					error(`no such directory {parent(path)}`)
				end
				h.files[path] = text
			end,
			list = function(path: string): { string }
				if not h.dirs[path] then
					error(`no such directory {path}`)
				end
				local out = {}
				for p in h.files do
					if parent(p) == path then
						table.insert(out, base(p))
					end
				end
				for p in h.dirs do
					if parent(p) == path then
						table.insert(out, base(p))
					end
				end
				table.sort(out)
				return out
			end,
			exists = function(path: string): boolean
				return h.files[path] ~= nil or h.dirs[path] == true
			end,
			mkdir = function(path: string)
				local p = path
				while p ~= "" and not h.dirs[p] do
					h.dirs[p] = true
					p = parent(p)
				end
			end,
			remove = function(path: string)
				if h.files[path] == nil then
					error(`no such file {path}`)
				end
				h.files[path] = nil
			end,
		},
		process = {
			run = function(argv: { string }, opts: any, cb: any)
				if h.missing[argv[1]] then
					error(`program not found: {argv[1]}`)
				end
				table.insert(h.procs, { argv = argv, opts = opts, done = cb })
			end,
		},
		timer = function(ms: number, fn: any): any
			local t = { ms = ms, fn = fn, cancelled = false }
			table.insert(h.timers, t)
			return {
				cancel = function()
					t.cancelled = true
				end,
			}
		end,
		carly = {
			export = function(name: string, spec: any, fn: any)
				h.exports[name] = { spec = spec, fn = fn }
			end,
			context = function(fn: any)
				h.context = fn
			end,
		},
		command = function(def: any)
			h.commands[def.id] = def
		end,
		on = function(name: string, fn: any)
			h.handlers[name] = fn
		end,
	}

	--- Runs every timer pending now (they re-arm themselves for the next call).
	h.fire = function(cx: any)
		local due = h.timers
		h.timers = {}
		for _, t in due do
			if not t.cancelled then
				t.fn(cx)
			end
		end
	end

	--- Ends the oldest pending process.
	h.finish = function(result: { stdout: string?, status: number?, stderr: string?, timed_out: boolean? })
		local proc = table.remove(h.procs, 1)
		assert(proc, "no pending process")
		proc.done({
			status = result.status or 0,
			stdout = result.stdout or "",
			stderr = result.stderr or "",
			timed_out = result.timed_out == true,
		}, nil)
	end

	--- Calls export `name` as Carly does: args, then a fresh cx and an ExportCall.
	h.call = function(name: string, cx: any, ...: any): (any, any)
		local call: any = { cancelled = false, replied = nil, failed = nil }
		function call.reply(self: any, v: any): boolean
			self.replied = v
			return true
		end
		function call.fail(self: any, m: string): boolean
			self.failed = m
			return true
		end
		function call.wait(_self: any, ms: number?): any
			return { wait = ms }
		end
		local args = table.pack(...)
		args[args.n + 1] = cx
		args[args.n + 2] = call
		local ret = h.exports[name].fn(table.unpack(args, 1, args.n + 2))
		return ret, call
	end

	--- A fake window: sessions with tabs, agents, toasts, Carly asks.
	h.window = function(): any
		local w: any = {
			key = "",
			sessions = { { id = 1, name = "Default" } },
			tabs = { { id = 10, session = 1, pane = 100, title = "pwsh" } },
			current = 1,
			focused = nil,
			closed = {},
			toasts = {},
			asked = {},
			started = {},
			agents_list = {},
			next_id = 200,
		}
		local cx: any = {}
		function cx.window_key(_self: any): string
			return w.key
		end
		function cx.toast(_self: any, level: string, text: string, sub: string?)
			table.insert(w.toasts, { level = level, text = text, sub = sub })
		end
		function cx.ask_carly(_self: any, text: string)
			table.insert(w.asked, text)
		end
		cx.agents = {
			start = function(_self: any, opts: any): number
				table.insert(w.started, opts)
				return 42
			end,
			list = function(_self: any): { any }
				return w.agents_list
			end,
		}
		cx.session = {
			find_session = function(_self: any, spec: string): number?
				for _, s in w.sessions do
					if s.name == spec then
						return s.id
					end
				end
				return nil
			end,
			tabs = function(_self: any): { any }
				return table.clone(w.tabs)
			end,
		}
		cx.sessions = {
			create = function(_self: any, opts: any): any
				w.next_id += 1
				local s = { id = w.next_id, name = opts.name }
				table.insert(w.sessions, s)
				w.next_id += 1
				table.insert(w.tabs, { id = w.next_id, session = s.id, pane = w.next_id * 10, title = "pwsh" })
				w.current = s.id
				return { id = s.id, name = s.name, host = 0, current = true, locked = false, tabs = 1 }
			end,
			switch = function(_self: any, s: number)
				w.current = s
			end,
		}
		cx.layout = {
			tab = function(_self: any, spec: any): (number?, string?)
				w.next_id += 1
				table.insert(w.tabs, {
					id = w.next_id,
					session = w.current,
					pane = w.next_id * 10,
					name = spec.name,
					title = spec.launch.command,
					command = spec.launch.command,
				})
				return w.next_id, nil
			end,
			color_tab = function(_self: any, tab: number, color: string)
				for _, t in w.tabs do
					if t.id == tab then
						t.color = color
					end
				end
			end,
			close = function(_self: any, pane: number)
				table.insert(w.closed, pane)
				for i, t in w.tabs do
					if t.pane == pane then
						table.remove(w.tabs, i)
						break
					end
				end
			end,
			focus = function(_self: any, pane: number)
				w.focused = pane
			end,
		}
		w.cx = cx
		return w
	end

	-- `require("./x")` resolves against the requiring file's folder.
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
	load(root .. "/window.luau")
	return h
end

return stub
