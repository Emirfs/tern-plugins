--!strict
-- `accounts` bloğu: her omp profili için `omp usage --json` çalıştırır,
-- aynı hesabı (sağlayıcı + e-posta/org) profiller arasında tekilleştirir ve
-- kalan limitleri hesap hesap, sağlayıcı başına toplamlarıyla gösterir.
-- Toplama `lib/usage`, boyut kararları `lib/layout`, metinler `lib/i18n` içinde.
--
-- Tuşlar: r yenile, R omp'nin kullanım önbelleğini temizleyip yenile, l dil.

local fmt = require("./lib/fmt")
local i18n = require("./lib/i18n")
local layout = require("./lib/layout")
local usage = require("./lib/usage")

type Account = usage.Account
type Cell = usage.Cell
type Column = usage.Column
type Provider = usage.Provider
type Issue = usage.Issue
type Layout = layout.Layout
type Strings = { [string]: string }

local ui = tern.ui

local REFRESH_MS = 2 * 60 * 1000
local TICK_MS = 30 * 1000
local OMP_TIMEOUT_MS = 60 * 1000
-- Son başarılı çekimin kırpılmış kopyası: yeni pane ilk çekim bitmeden çizer.
local CACHE_KEY = "cache"
local CACHE_VERSION = 1

local PROVIDER_NAMES = {
	anthropic = "Claude",
	["openai-codex"] = "Codex",
	["google-antigravity"] = "Antigravity",
	["github-copilot"] = "Copilot",
}

-- Bir profil çalıştırmasının hatası; metne görünüm, o anki dilde çevirir.
type RunError = { code: string, detail: string?, status: number? }

type ProfileRun = {
	name: string,
	-- Son başarılı çıktı (kırpılmış); sonraki çekim başarısız olsa da kalır.
	data: any?,
	err: RunError?,
	-- `data`nın alındığı an (epoch s).
	at: number?,
}

type State = {
	cx: BlockCx,
	profiles: { [string]: ProfileRun },
	order: { string },
	loading: boolean,
	fetched: number?,
	-- Veri önbellekten geliyor, bu blok henüz kendi çekimini bitirmedi.
	cached: boolean,
	timer: TimerHandle?,
	ticks: number,
}

-- Pane id'si yeniden başlatmada aynı kalır; state nesnesi bu çalışmayı tanımlar.
local running: { [number]: State } = {}

local function strings(): Strings
	return i18n.strings(i18n.current(tern))
end

---------------------------------------------------------------------------
-- Ortam: ev dizini, profiller, omp yürütülebilir dosyası

local function home_dir(): string?
	return tern.getenv("USERPROFILE") or tern.getenv("HOME")
end

local function join(a: string, b: string): string
	local sep = if string.find(a, "\\", 1, true) then "\\" else "/"
	if string.sub(a, -1) == sep then
		return a .. b
	end
	return a .. sep .. b
end

-- Varsayılan profil (~/.omp/agent) ve ~/.omp/profiles altındaki her profil.
local function discover_profiles(): { string }
	local found: { string } = {}
	local home = home_dir()
	if not home then
		return found
	end
	local root = join(home, ".omp")
	if tern.fs.exists(join(root, "agent")) then
		table.insert(found, "default")
	end
	local dir = join(root, "profiles")
	local ok, names = pcall(tern.fs.list, dir)
	if ok and type(names) == "table" then
		for _, name in names do
			if name ~= "default" and tern.fs.exists(join(join(dir, name), "agent")) then
				table.insert(found, name)
			end
		end
	end
	return found
end

-- Daemon'un PATH'i kabuğunkinden dar olabilir: önce adıyla, sonra bu işletim
-- sisteminde omp'nin kurulduğu bilinen yerler.
local function omp_candidates(): { string }
	local list = { "omp" }
	local home = home_dir()
	local extra: { string } = {}
	if tern.runtime.os == "windows" then
		local lad = tern.getenv("LOCALAPPDATA")
		if lad then
			table.insert(extra, join(lad, "Tern\\omp\\bin\\omp.exe"))
		end
		if home then
			table.insert(extra, join(home, ".bun\\bin\\omp.exe"))
		end
	else
		if home then
			table.insert(extra, join(home, ".bun/bin/omp"))
		end
		table.insert(extra, "/opt/homebrew/bin/omp")
		table.insert(extra, "/usr/local/bin/omp")
	end
	for _, path in extra do
		if tern.fs.exists(path) then
			table.insert(list, path)
		end
	end
	return list
end

-- `omp [--profile P] <args>` çalıştırır. OMP_PROFILE, daemon ortamından
-- sızabilecek PI_PROFILE'ı ezer; varsayılan profilde PI_CODING_AGENT_DIR de
-- sabitlenir. Hiçbir aday başlamazsa son başlatma hatasını döndürür (yoksa nil:
-- "bulunamadı").
local function run_omp(profile: string, args: { string }, done: (ProcessResult) -> ()): (boolean, string?)
	local env: { [string]: string } = { OMP_PROFILE = profile, NO_COLOR = "1" }
	local home = home_dir()
	if profile == "default" and home then
		env.PI_CODING_AGENT_DIR = join(join(home, ".omp"), "agent")
	end
	local last: string? = nil
	for _, exe in omp_candidates() do
		local argv: { string } = { exe }
		if profile ~= "default" then
			table.insert(argv, "--profile")
			table.insert(argv, profile)
		end
		for _, a in args do
			table.insert(argv, a)
		end
		local ok, err = pcall(function()
			tern.process.run(argv, { timeout_ms = OMP_TIMEOUT_MS, env = env }, function(result: ProcessResult, _)
				done(result)
			end)
		end)
		if ok then
			return true, nil
		end
		last = tostring(err)
	end
	return false, last
end

---------------------------------------------------------------------------
-- Önbellek: son başarılı çekim, `tern.kv` içinde (bütün pane'ler ve pencereler paylaşır)

local function load_cache(state: State)
	local ok, cache = pcall(tern.kv.get, CACHE_KEY)
	if not ok or type(cache) ~= "table" or cache.v ~= CACHE_VERSION or type(cache.profiles) ~= "table" then
		return
	end
	local order: { string } = {}
	for _, name in (if type(cache.order) == "table" then cache.order else {}) do
		local entry = cache.profiles[name]
		if type(name) == "string" and type(entry) == "table" and type(entry.data) == "table" then
			table.insert(order, name)
			state.profiles[name] = { name = name, data = entry.data, at = entry.at }
		end
	end
	if #order > 0 then
		state.order = order
		state.fetched = if type(cache.fetched) == "number" then cache.fetched else nil
		state.cached = true
	end
end

local function store_cache(state: State)
	local profiles: { [string]: any } = {}
	local any_data = false
	for _, name in state.order do
		local run = state.profiles[name]
		if run and run.data then
			profiles[name] = { data = run.data, at = run.at }
			any_data = true
		end
	end
	if any_data then
		pcall(tern.kv.set, CACHE_KEY, { v = CACHE_VERSION, fetched = state.fetched, order = state.order, profiles = profiles })
	end
end

---------------------------------------------------------------------------
-- Yaşam döngüsü ve veri çekme

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	state.loading = false
end

-- Bloğun kapanma kancası yok: geri çağrılar kaybolan pane'i kendileri emekliye ayırır.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

-- Her profil için `args` çalıştırır; hepsi bitince `finish` çağrılır.
local function each_profile(
	state: State,
	args: { string },
	on_result: (string, ProcessResult?, RunError?) -> (),
	finish: () -> ()
)
	local names = discover_profiles()
	state.order = names
	if #names == 0 then
		finish()
		return
	end
	local left = #names
	local function settle()
		left -= 1
		if left == 0 then
			finish()
		end
	end
	for _, name in names do
		local started, spawn_error = run_omp(name, args, function(result)
			if not alive(state) then
				return
			end
			on_result(name, result, nil)
			settle()
		end)
		if not started then
			on_result(name, nil, if spawn_error then { code = "err_spawn", detail = spawn_error } else { code = "err_not_found" })
			settle()
		end
	end
end

-- Bir çalıştırmanın sonucu: veri ya da hata. Hata önceki veriyi silmez.
local function apply_result(run: ProfileRun, result: ProcessResult?, spawn_error: RunError?)
	if spawn_error then
		run.err = spawn_error
	elseif result == nil then
		run.err = { code = "err_none" }
	elseif result.timed_out then
		run.err = { code = "err_timeout" }
	elseif result.status ~= 0 then
		run.err = { code = "err_status", status = result.status, detail = fmt.first_line(result.stderr) }
	else
		local ok, data = pcall(tern.json.decode, result.stdout)
		local trimmed = if ok then usage.trim(data) else nil
		if trimmed then
			run.data, run.err, run.at = trimmed, nil, os.time()
		else
			run.err = { code = "err_output", detail = fmt.first_line(result.stdout) }
		end
	end
end

local function refresh(state: State, invalidate: boolean?)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true

	local function fetch_all()
		each_profile(state, { "usage", "--json" }, function(name, result, spawn_error)
			local run = state.profiles[name] or { name = name }
			state.profiles[name] = run
			apply_result(run, result, spawn_error)
		end, function()
			if not alive(state) then
				return
			end
			-- Artık bulunmayan profilleri at.
			for name in state.profiles do
				if not table.find(state.order, name) then
					state.profiles[name] = nil
				end
			end
			state.loading = false
			state.fetched = os.time()
			state.cached = false
			store_cache(state)
			state.cx:render()
		end)
	end

	if invalidate then
		each_profile(state, { "usage", "invalidate" }, function() end, function()
			if alive(state) then
				fetch_all()
			end
		end)
	else
		fetch_all()
	end
end

-- Tek bir bekleyen zamanlayıcı: her 30 sn sıfırlanma sayaçlarını tazeler,
-- her REFRESH_MS'de bir veriyi yeniden çeker.
local function schedule(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(TICK_MS, function()
		state.timer = nil
		if not alive(state) then
			return
		end
		state.ticks += 1
		if state.ticks * TICK_MS >= REFRESH_MS then
			state.ticks = 0
			refresh(state)
		end
		state.cx:render()
		schedule(state)
	end)
end

---------------------------------------------------------------------------
-- Görünüm

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function provider_name(id: string): string
	return PROVIDER_NAMES[id] or id
end

local function shape_of(providers: { Provider }): layout.Shape
	local shape: layout.Shape = {}
	for _, prov in providers do
		table.insert(shape, #prov.accounts)
	end
	return shape
end

-- Kalan orana göre renk: biten kırmızı, %20 altı sarı, gerisi temanın vurgu rengi.
local function level_tone(left: number, status: string?): string?
	if left <= 0.0001 or status == "exhausted" then
		return "error"
	elseif left < 0.2 then
		return "warning"
	end
	return nil
end

local function remaining_spans(used: number, status: string?, L: Strings, suffix: string?): { Span | string }
	local left = 1 - used
	local tone = level_tone(left, status)
	return { ui.span(fmt.pct(left, L) .. (suffix or ""), if tone then tone .. " strong" else "strong") }
end

-- Dolu çubuk = kalan kota (pil gibi), az kalınca sarı/kırmızı.
local function remaining_meter_cell(cell: Cell): MeterCell
	local left = 1 - cell.used
	local m = ui.meter_cell(left)
	local tone = level_tone(left, cell.status)
	if tone then
		m.meter.tone = tone
	end
	return m
end

-- E-postanın yerel kısmı ve varsa org/plan: "emir.sari · Inohom".
local function who(acc: Account, L: Strings): string
	local label = acc.label or L.unknown_account
	local name = string.match(label, "^([^@]+)@") or label
	return if acc.org then name .. " · " .. acc.org else name
end

local function account_label(acc: Account, lead: { Span | string }, tone: string?, L: Strings): { Span | string }
	local spans = table.clone(lead)
	table.insert(spans, ui.span(who(acc, L), tone))
	if acc.resets > 0 then
		table.insert(spans, ui.span(string.format(L.resets_credit, acc.resets), "success"))
	end
	return spans
end

-- Bir satırın pencere hücreleri: kalan, (çubuk), (sıfırlanma ya da toplam notu).
local function window_cells(row: { any }, lay: Layout, cell: Cell?, note: { Span | string }?, L: Strings)
	if cell == nil then
		table.insert(row, { ui.span("—", "dim") })
	else
		table.insert(row, remaining_spans(cell.used, cell.status, L))
	end
	if lay.bars then
		table.insert(row, if cell then remaining_meter_cell(cell) else "")
	end
	if lay.resets then
		table.insert(row, if cell then (note or { ui.span(fmt.until_text(cell.resets, os.time(), L), "muted") }) else "")
	end
end

-- Birden çok hesabı olan sağlayıcının pencere toplamı: hesapların kalan
-- kotasının ortalaması, yani toplam kotanın kalan yüzdesi.
local function total_cell(prov: Provider, key: string, L: Strings): (Cell?, { Span | string }?)
	local used, n = 0, 0
	for _, acc in prov.accounts do
		local c = acc.windows[key]
		if c then
			used += c.used
			n += 1
		end
	end
	if n == 0 then
		return nil, nil
	end
	return { used = used / n }, { ui.span(L.total, "muted") }
end

-- Görünümün bir satırı: etiket ve sütun başına hücre (toplam satırında not).
type Line = { label: { Span | string }, cells: { [number]: Cell }, notes: { [number]: { Span | string } } }

local function account_line(label: { Span | string }, acc: Account, columns: { Column }): Line
	local cells: { [number]: Cell } = {}
	for i, c in columns do
		cells[i] = acc.windows[c.key]
	end
	return { label = label, cells = cells, notes = {} }
end

-- Tek hesaplı sağlayıcı bir satır; çok hesaplıda toplam satırı ve (sığarsa) altında hesaplar.
local function lines_of(providers: { Provider }, columns: { Column }, lay: Layout, L: Strings): { Line }
	local out: { Line } = {}
	for _, prov in providers do
		local name = provider_name(prov.id)
		if #prov.accounts == 1 then
			local acc = prov.accounts[1]
			local label = if lay.narrow
				then { ui.span(name, "strong") }
				else account_label(acc, { ui.span(name .. " ", "strong") }, "muted", L)
			table.insert(out, account_line(label, acc, columns))
		else
			local label: { Span | string } = { ui.span(name, "strong") }
			if not lay.narrow then
				table.insert(label, ui.span(string.format(L.n_accounts, #prov.accounts), "muted"))
			end
			local total: Line = { label = label, cells = {}, notes = {} }
			for i, c in columns do
				local cell, note = total_cell(prov, c.key, L)
				if cell and note then
					total.cells[i] = cell
					total.notes[i] = note
				end
			end
			table.insert(out, total)
			if not lay.collapse then
				for _, acc in prov.accounts do
					table.insert(out, account_line(account_label(acc, { ui.span("› ", "dim") }, nil, L), acc, columns))
				end
			end
		end
	end
	return out
end

-- Tablo: sütunlar en düşük öncelikten gizlenir (çubuk, sıfırlanma, sonraki
-- pencereler); etiket ve ilk pencere en son.
local function table_view(lines: { Line }, columns: { Column }, lay: Layout, L: Strings): Node
	local cols: { Col } = { { id = "account", head = L.col_account, grow = 1, truncate = "end", priority = 3 } }
	for i, c in columns do
		table.insert(cols, { id = "p" .. i, head = c.label, align = "end", priority = if i == 1 then 2 else 1 })
		if lay.bars then
			table.insert(cols, { id = "b" .. i, head = "", grow = 1, priority = -2 })
		end
		if lay.resets then
			table.insert(cols, { id = "r" .. i, head = L.col_resets, align = "end", priority = -1 })
		end
	end
	local rows: { { any } } = {}
	for _, line in lines do
		local row: { any } = { line.label }
		for i in columns do
			window_cells(row, lay, line.cells[i], line.notes[i], L)
		end
		table.insert(rows, row)
	end
	return with(ui.table(cols, rows), { key = "accounts" })
end

-- En dar pane: tablo etiketi taşıyamaz; liste etiketi kırpar, sığan kadar
-- pencerenin yüzdesi sağda kalır.
local function list_view(lines: { Line }, columns: { Column }, cx: BlockCx, L: Strings): Node
	local shown = math.clamp(math.floor((cx.cols - 9) / 5), 1, math.max(1, #columns))
	local heads: { string } = {}
	for i = 1, math.min(shown, #columns) do
		local c = columns[i]
		local short = if c.duration then fmt.window_name(c.duration, L, true) else c.label
		table.insert(heads, if c.meter then short .. " " .. c.meter else short)
	end
	local items: { Item } = { { label = { ui.span(L.col_account, "dim") }, value = { ui.span(table.concat(heads, " "), "dim") } } }
	for _, line in lines do
		local value: { Span | string } = {}
		for i = 1, math.min(shown, #columns) do
			if i > 1 then
				table.insert(value, " ")
			end
			local cell = line.cells[i]
			if cell then
				for _, s in remaining_spans(cell.used, cell.status, L) do
					table.insert(value, s)
				end
			else
				table.insert(value, ui.span("—", "dim"))
			end
		end
		table.insert(items, { label = line.label, value = value })
	end
	return with(ui.list(items), { key = "accounts-list" })
end

-- Geniş ve uzun pane için yığılı görünümün bir pencere satırı: pencere adı,
-- kalan yüzde, kalanı gösteren çubuk ve yenilenmeye kalan süre.
local function window_row(c: Column, cell: Cell?, wide: boolean, key: string, L: Strings): Node
	local name = with(ui.text({ ui.span(c.label, "muted") }), { min = { w = "8ch" } })
	if cell == nil then
		return with(ui.row({ name, ui.text({ ui.span(L.not_reported, "dim") }) }), { key = key, role = "omp-usage.window" })
	end
	local left = 1 - cell.used
	local meter: { [string]: any } = { value = left, size = "md", grow = 1 }
	meter.tone = level_tone(left, cell.status)
	local reset = fmt.until_text(cell.resets, os.time(), L)
	return with(ui.row({
		name,
		with(ui.text(remaining_spans(cell.used, cell.status, L, if wide then L.left else nil)), {
			min = { w = if wide then "10ch" else "5ch" },
		}),
		ui.node("meter", meter),
		with(ui.text({ ui.span(if wide then string.format(L.resets_in, reset) else reset, "muted") }), {
			min = { w = if wide then "23ch" else "8ch" },
		}),
	}), { key = key, role = "omp-usage.window" })
end

-- Sağlayıcı başlığı: tek hesapta hesap adı, çok hesapta hesap sayısı ve
-- pencere başına toplam kalan.
local function provider_header(prov: Provider, columns: { Column }, L: Strings): Node
	local spans: { Span | string } = { ui.span(provider_name(prov.id), "strong") }
	if #prov.accounts == 1 then
		for _, s in account_label(prov.accounts[1], { ui.span(" · ", "dim") }, "muted", L) do
			table.insert(spans, s)
		end
	else
		table.insert(spans, ui.span(" ·" .. string.format(L.n_accounts, #prov.accounts), "muted"))
		local parts: { string } = {}
		for _, c in columns do
			local cell = total_cell(prov, c.key, L)
			if cell then
				table.insert(parts, c.label .. " " .. fmt.pct(1 - cell.used, L))
			end
		end
		if #parts > 0 then
			table.insert(spans, ui.span(string.format(L.total_left, table.concat(parts, ", ")), "muted"))
		end
	end
	return with(ui.text(spans), { key = "head", role = "omp-usage.provider" })
end

-- Boş alanı okunabilirliğe harcayan görünüm: sağlayıcı grupları ayraçla
-- ayrılır, her hesabın her penceresi kendi çubuğuyla bir satır. Sığmazsa nil.
local function roomy_view(providers: { Provider }, columns: { Column }, status: { Node }, cx: BlockCx, L: Strings): { Node }?
	local fits, wide = layout.roomy(shape_of(providers), #columns, #status, cx.cols, cx.rows)
	if not fits then
		return nil
	end
	local children: { Node } = {}
	for gi, prov in providers do
		if gi > 1 then
			table.insert(children, with(ui.rule(""), { key = "rule:" .. prov.id }))
		end
		local group: { Node } = { provider_header(prov, columns, L) }
		for ai, acc in prov.accounts do
			if #prov.accounts > 1 then
				table.insert(group, with(ui.text(account_label(acc, {}, nil, L)), { key = "a" .. ai, role = "omp-usage.account" }))
			end
			for wi, c in columns do
				table.insert(group, window_row(c, acc.windows[c.key], wide, string.format("a%dw%d", ai, wi), L))
			end
		end
		table.insert(children, with(ui.col(group), { key = "g:" .. prov.id }))
	end
	for _, line in status do
		table.insert(children, line)
	end
	return children
end

-- Hesap görünümü ve sığdığı kadar durum satırı: yer varsa yığılı görünüm,
-- yoksa tablo, en darda liste.
local function accounts_view(providers: { Provider }, status: { Node }, cx: BlockCx, L: Strings): { Node }
	local columns = usage.columns_of(providers, L)
	local roomy = roomy_view(providers, columns, status, cx, L)
	if roomy then
		return roomy
	end
	local lay = layout.table_for(shape_of(providers), #columns, #status, cx.cols, cx.rows)
	local lines = lines_of(providers, columns, lay, L)
	local body = if lay.tiny then list_view(lines, columns, cx, L) else table_view(lines, columns, lay, L)
	local children: { Node } = { body }
	-- Yer yoksa sade durum satırı düşer; sorun satırı her zaman kalır.
	local room = lay.capacity - lay.table_lines
	for i, line in status do
		if i > 1 or room >= #status then
			table.insert(children, line)
		end
	end
	return children
end

local function has_data(state: State): boolean
	for _, run in state.profiles do
		if run.data then
			return true
		end
	end
	return false
end

local function error_text(err: RunError, L: Strings): string
	local f = L[err.code] or err.code
	if err.code == "err_status" then
		return string.format(f, err.status or -1, err.detail or "")
	end
	return if err.detail then string.format(f, err.detail) else f
end

local function issue_text(it: Issue, L: Strings): string
	return if it.kind == "disabled" then string.format(L.issue_disabled, it.detail or "") else L.issue_no_report
end

-- Tablonun altındaki durum satırı; sorun varsa ikinci satır (profil hatası ya
-- da devre dışı hesap). Dock yerine ana bölgede: dock pane'in alt kenarında kırpılıyor.
local function status_lines(state: State, issues: { Issue }, L: Strings): { Node }
	local status: { Span | string } = { ui.span(string.format(L.profiles, #state.order), "muted") }
	if state.loading and not state.cached then
		table.insert(status, ui.span(L.refreshing, "muted"))
	elseif state.fetched then
		local text = string.format(L.updated, os.date("%H:%M", state.fetched))
		table.insert(status, ui.span(if state.cached then text .. L.cached else text, "muted"))
	end
	-- Dar pane'de ipucu satırı kaydırmasın diye düşer.
	if state.cx.cols >= layout.HINT_COLS then
		table.insert(status, ui.span(L.hint, "dim"))
	end
	local lines: { Node } = { with(ui.text(status), { key = "status" }) }

	local problems: { string } = {}
	for _, name in state.order do
		local run = state.profiles[name]
		if run and run.err then
			local text = name .. ": " .. error_text(run.err, L)
			-- Hata önceki veriyi silmez; hangi anın verisi gösterildiğini söyle.
			if run.data and run.at then
				text ..= " — " .. string.format(L.stale, os.date("%H:%M", run.at))
			end
			table.insert(problems, text)
		end
	end
	for _, it in issues do
		table.insert(problems, provider_name(it.provider) .. " " .. it.who .. ": " .. issue_text(it, L))
	end
	if #problems > 0 then
		local text = problems[1]
		if #problems > 1 then
			text ..= string.format(" (+%d)", #problems - 1)
		end
		table.insert(lines, with(ui.text({ ui.span("⚠ " .. text, "warning") }), { key = "problem" }))
	end
	return lines
end

tern.block.define("accounts", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local state: State = {
			cx = cx,
			profiles = {},
			order = {},
			loading = false,
			fetched = nil,
			cached = false,
			timer = nil,
			ticks = 0,
		}
		running[cx.pane] = state
		load_cache(state)
		refresh(state)
		schedule(state)
		return state
	end,

	title = function(state: State): string?
		local L = strings()
		if not has_data(state) then
			return L.title
		end
		local providers = usage.aggregate(state.order, state.profiles :: any)
		local n = 0
		for _, p in providers do
			n += #p.accounts
		end
		return string.format(L.title_count, n)
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local L = strings()
		if not has_data(state) then
			local main: Node
			if state.loading or not state.fetched then
				main = ui.progress(nil, L.loading)
			elseif #state.order == 0 then
				main = ui.md(L.no_profiles)
			else
				main = ui.md(L.none_read)
			end
			local children: { Node } = { main }
			for _, line in status_lines(state, {}, L) do
				table.insert(children, line)
			end
			return { main = ui.col(children) }
		end
		local providers, issues = usage.aggregate(state.order, state.profiles :: any)
		return { main = ui.col(accounts_view(providers, status_lines(state, issues, L), state.cx, L)) }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "r" then
			refresh(state)
		elseif k == "R" then
			refresh(state, true)
		elseif k == "l" then
			tern.kv.set(i18n.KV_KEY, i18n.other(i18n.current(tern)))
		else
			return false
		end
		return true
	end,
})
