-- `accounts` bloğu: her omp profili için `omp usage --json` çalıştırır,
-- aynı hesabı (sağlayıcı + e-posta/org) profiller arasında tekilleştirir ve
-- kalan limitleri hesap hesap, sağlayıcı başına toplamlarıyla gösterir.
--
-- Tuşlar: r yenile, R omp'nin kullanım önbelleğini temizleyip yenile.

local ui = tern.ui

local REFRESH_MS = 2 * 60 * 1000
local TICK_MS = 30 * 1000
local OMP_TIMEOUT_MS = 60 * 1000

local PROVIDER_ORDER = { "anthropic", "openai-codex", "google-antigravity" }
local PROVIDER_NAMES = {
	anthropic = "Claude",
	["openai-codex"] = "Codex",
	["google-antigravity"] = "Antigravity",
	["github-copilot"] = "Copilot",
}

type ProfileRun = {
	name: string,
	data: any?,
	err: string?,
	at: number?,
}

type State = {
	cx: BlockCx,
	profiles: { [string]: ProfileRun },
	order: { string },
	loading: boolean,
	fetched: number?,
	timer: TimerHandle?,
	ticks: number,
}

-- Pane id'si yeniden başlatmada aynı kalır; state nesnesi bu çalışmayı tanımlar.
local running: { [number]: State } = {}

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

-- Daemon'un PATH'i kabuğunkinden dar olabilir: önce adıyla, sonra bilinen yerler.
local function omp_candidates(): { string }
	local list = { "omp" }
	local home = home_dir()
	local lad = tern.getenv("LOCALAPPDATA")
	local extra: { string } = {}
	if lad then
		table.insert(extra, join(lad, "Tern\\omp\\bin\\omp.exe"))
	end
	if home then
		table.insert(extra, join(home, ".bun\\bin\\omp.exe"))
		table.insert(extra, join(home, ".bun/bin/omp"))
	end
	table.insert(extra, "/opt/homebrew/bin/omp")
	table.insert(extra, "/usr/local/bin/omp")
	for _, path in extra do
		if tern.fs.exists(path) then
			table.insert(list, path)
		end
	end
	return list
end

-- `omp [--profile P] <args>` çalıştırır. OMP_PROFILE, daemon ortamından
-- sızabilecek PI_PROFILE'ı ezer; varsayılan profilde PI_CODING_AGENT_DIR de
-- sabitlenir. Hiçbir aday başlamazsa son başlatma hatasını döndürür.
local function run_omp(profile: string, args: { string }, done: (ProcessResult) -> ()): string?
	local env: { [string]: string } = { OMP_PROFILE = profile, NO_COLOR = "1" }
	local home = home_dir()
	if profile == "default" and home then
		env.PI_CODING_AGENT_DIR = join(join(home, ".omp"), "agent")
	end
	local last = "omp bu makinenin PATH'inde bulunamadı"
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
			return nil
		end
		last = tostring(err)
	end
	return last
end

---------------------------------------------------------------------------
-- Biçimlendirme

local function first_line(text: string): string
	return string.match(text, "[^\r\n]+") or ""
end

local function window_name(ms: number?): string
	if not ms then
		return "?"
	end
	local hours = ms / 3600000
	if hours < 48 then
		return string.format("%d saat", math.floor(hours + 0.5))
	end
	return string.format("%d gün", math.floor(hours / 24 + 0.5))
end

local function until_text(resets_ms: number?): string
	if type(resets_ms) ~= "number" then
		return "—"
	end
	local s = math.floor(resets_ms / 1000 - os.time())
	if s <= 0 then
		return "şimdi"
	elseif s < 60 then
		return "<1dk"
	elseif s < 3600 then
		return string.format("%ddk", s // 60)
	elseif s < 86400 then
		return string.format("%dsa%02ddk", s // 3600, (s % 3600) // 60)
	end
	return string.format("%dg%02dsa", s // 86400, (s % 86400) // 3600)
end

local function pct(fraction: number): string
	return string.format("%%%d", math.floor(fraction * 100 + 0.5))
end

local function provider_name(id: string): string
	return PROVIDER_NAMES[id] or id
end

---------------------------------------------------------------------------
-- Toplama

type Limit = {
	key: string,
	label: string,
	used: number?,
	resets: number?,
	duration: number?,
	meter: string?,
	status: string?,
}

type Account = {
	provider: string,
	key: string,
	label: string,
	org: string?,
	profiles: { string },
	fetched: number,
	limits: { Limit },
	resets: number,
	windows: { [string]: Cell },
}

-- Bir hesabın bir penceredeki bağlayıcı (en çok kullanılmış) limiti.
type Cell = { used: number, resets: number?, status: string? }

-- Tablonun bir pencere sütunu: süre (5 saat, 7 gün) ve varsa ayrı kota havuzu.
type Column = { key: string, label: string, duration: number?, meter: string? }

type Provider = { id: string, accounts: { Account } }

type Issue = { provider: string, who: string, text: string, profiles: { string } }

-- omp'nin `resolveUsedFraction` karşılığı: kullanılan oran, 0–1.
local function used_fraction(amount: any): number?
	if type(amount) ~= "table" then
		return nil
	end
	local f: number? = nil
	if type(amount.usedFraction) == "number" then
		f = amount.usedFraction
	elseif type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0 then
		f = amount.used / amount.limit
	elseif type(amount.remainingFraction) == "number" then
		f = 1 - amount.remainingFraction
	end
	if f == nil then
		return nil
	end
	return math.clamp(f, 0, 1)
end

-- omp'nin `meterForLimit` karşılığı: aynı pencerede ayrı kota havuzu tutan limitler.
local function meter_of(provider: string, limit: any): string?
	if provider ~= "anthropic" and provider ~= "openai-codex" then
		return nil
	end
	local scope = if type(limit.scope) == "table" then limit.scope else {}
	local tier = if type(scope.tier) == "string" then string.lower(string.match(scope.tier, "^%s*(.-)%s*$") or "") else ""
	if tier ~= "" then
		return tier
	end
	if provider ~= "openai-codex" then
		return nil
	end
	local slug = string.match(string.lower(tostring(limit.id or "")), "^[^:]*:([^:]+)")
	if slug and slug ~= "primary" and slug ~= "secondary" then
		return slug
	end
	return "chat"
end

local function limit_label(limit: any): string
	local label = tostring(limit.label or limit.id or "?")
	local win = if type(limit.window) == "table" then limit.window.label else nil
	if type(win) == "string" and not string.find(string.lower(label), string.lower(win), 1, true) then
		return label .. " (" .. win .. ")"
	end
	return label
end

local function identity(provider: string, md: any): string?
	if type(md) ~= "table" then
		return nil
	end
	if type(md.email) == "string" then
		return provider .. "|email:" .. string.lower(md.email) .. (if type(md.orgId) == "string" then "|org:" .. md.orgId else "")
	end
	if type(md.accountId) == "string" then
		return provider .. "|acct:" .. md.accountId
	end
	return nil
end

local function org_text(md: any): string?
	if type(md) ~= "table" or type(md.orgName) ~= "string" then
		return nil
	end
	if type(md.email) == "string" and md.orgName == md.email .. "'s Organization" then
		return nil
	end
	return md.orgName
end

local function add_unique(list: { string }, value: string)
	if not table.find(list, value) then
		table.insert(list, value)
	end
end

local function account_of(provider: string, report: any, profile: string, index: number): Account
	local md = report.metadata
	local key = identity(provider, md) or (provider .. "|" .. profile .. "#" .. index)
	local label = if type(md) == "table" then (md.email or md.accountId or md.projectId) else nil
	local limits: { Limit } = {}
	local seen: { [string]: boolean } = {}
	for _, limit in (if type(report.limits) == "table" then report.limits else {}) do
		local scope = if type(limit.scope) == "table" then limit.scope else {}
		local window = if type(limit.window) == "table" then limit.window else {}
		-- Antigravity aynı paylaşılan kotayı (Claude & GPT) iki kez raporlar.
		local lkey = if type(scope.sharedGroup) == "string" then "g:" .. scope.sharedGroup else "i:" .. tostring(limit.id)
		if not seen[lkey] then
			seen[lkey] = true
			table.insert(limits, {
				key = lkey,
				label = limit_label(limit),
				used = used_fraction(limit.amount),
				resets = if type(window.resetsAt) == "number" then window.resetsAt else nil,
				duration = if type(window.durationMs) == "number" then window.durationMs else nil,
				meter = meter_of(provider, limit),
				status = if type(limit.status) == "string" then limit.status else nil,
			})
		end
	end
	table.sort(limits, function(a, b)
		local da, db = a.duration or math.huge, b.duration or math.huge
		if da ~= db then
			return da < db
		end
		return a.label < b.label
	end)
	local credits = if type(report.resetCredits) == "table" then report.resetCredits.availableCount else nil
	return {
		provider = provider,
		key = key,
		label = tostring(label or "bilinmeyen hesap"),
		org = org_text(md),
		profiles = { profile },
		fetched = if type(report.fetchedAt) == "number" then report.fetchedAt else 0,
		limits = limits,
		resets = if type(credits) == "number" then credits else 0,
		windows = {},
	}
end

-- Pencere anahtarı süreye göre; Codex'in varsayılan "chat" havuzu dışındaki
-- ayrı havuzlar (model kapsamlı tier, Spark) kendi sütununu alır.
local function window_key(l: Limit): string
	local wkey = if l.duration then "d:" .. l.duration else "l:" .. l.label
	local meter = if l.meter == "chat" then nil else l.meter
	return if meter then wkey .. "|m:" .. meter else wkey
end

-- omp'nin `computeProviderWindowStats` mantığı: pencere başına hesabın en çok
-- kullanılan limiti o pencerede hesabı bağlar.
local function windows_of(acc: Account): { [string]: Cell }
	local out: { [string]: Cell } = {}
	for _, l in acc.limits do
		local used = l.used
		if used ~= nil then
			local key = window_key(l)
			local c = out[key]
			if c == nil or used > c.used then
				out[key] = { used = used, resets = l.resets, status = l.status }
			end
		end
	end
	return out
end

local function columns_of(providers: { Provider }): { Column }
	local seen: { [string]: boolean } = {}
	local list: { Column } = {}
	for _, prov in providers do
		for _, acc in prov.accounts do
			for _, l in acc.limits do
				local key = window_key(l)
				if l.used ~= nil and not seen[key] then
					seen[key] = true
					local meter = if l.meter == "chat" then nil else l.meter
					local label = if l.duration then window_name(l.duration) else l.label
					table.insert(list, {
						key = key,
						label = if meter then label .. " " .. meter else label,
						duration = l.duration,
						meter = meter,
					})
				end
			end
		end
	end
	table.sort(list, function(a, b)
		local da, db = a.duration or math.huge, b.duration or math.huge
		if da ~= db then
			return da < db
		end
		return (a.meter or "") < (b.meter or "")
	end)
	return list
end

local function aggregate(state: State): ({ Provider }, { Issue })
	local by_key: { [string]: Account } = {}
	local by_provider: { [string]: { Account } } = {}
	local issues: { [string]: Issue } = {}
	local issue_list: { Issue } = {}

	local function issue(provider: string, entry: any, text: string, profile: string)
		local who = tostring(entry.email or entry.accountId or entry.orgName or "?")
		local key = provider .. "|" .. who .. "|" .. text
		local found = issues[key]
		if found then
			add_unique(found.profiles, profile)
			return
		end
		local item: Issue = { provider = provider, who = who, text = text, profiles = { profile } }
		issues[key] = item
		table.insert(issue_list, item)
	end

	for _, name in state.order do
		local data = state.profiles[name] and state.profiles[name].data
		if type(data) == "table" then
			for i, report in (if type(data.reports) == "table" then data.reports else {}) do
				local provider = tostring(report.provider or "?")
				local acc = account_of(provider, report, name, i)
				local prev = by_key[acc.key]
				if prev then
					add_unique(prev.profiles, name)
					-- Aynı hesabın en taze raporu kazanır.
					if acc.fetched > prev.fetched then
						prev.fetched, prev.limits, prev.resets = acc.fetched, acc.limits, acc.resets
						prev.org = acc.org or prev.org
					end
				else
					by_key[acc.key] = acc
					by_provider[provider] = by_provider[provider] or {}
					table.insert(by_provider[provider], acc)
				end
			end
			for _, entry in (if type(data.accountsWithoutUsage) == "table" then data.accountsWithoutUsage else {}) do
				issue(tostring(entry.provider or "?"), entry, "kullanım raporu yok", name)
			end
			for _, entry in (if type(data.disabledCredentials) == "table" then data.disabledCredentials else {}) do
				issue(tostring(entry.provider or "?"), entry, "devre dışı: " .. first_line(tostring(entry.cause or "")), name)
			end
		end
	end

	local ids: { string } = {}
	for id in by_provider do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ia, ib = table.find(PROVIDER_ORDER, a) or 99, table.find(PROVIDER_ORDER, b) or 99
		if ia ~= ib then
			return ia < ib
		end
		return a < b
	end)

	local providers: { Provider } = {}
	for _, id in ids do
		local accounts = by_provider[id]
		table.sort(accounts, function(a, b)
			return a.label < b.label
		end)
		for _, acc in accounts do
			table.sort(acc.profiles)
		end
		for _, acc in accounts do
			acc.windows = windows_of(acc)
		end
		table.insert(providers, { id = id, accounts = accounts })
	end
	return providers, issue_list
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
local function each_profile(state: State, args: { string }, on_result: (string, ProcessResult?, string?) -> (), finish: () -> ())
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
		local spawn_error = run_omp(name, args, function(result)
			if not alive(state) then
				return
			end
			on_result(name, result, nil)
			settle()
		end)
		if spawn_error then
			on_result(name, nil, spawn_error)
			settle()
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
			if spawn_error then
				run.err = "omp başlatılamadı: " .. spawn_error
			elseif result == nil then
				run.err = "sonuç yok"
			elseif result.timed_out then
				run.err = "omp 60 saniyede yanıt vermedi"
			elseif result.status ~= 0 then
				run.err = "omp çıkış kodu " .. result.status .. ": " .. first_line(result.stderr)
			else
				local ok, data = pcall(tern.json.decode, result.stdout)
				if ok and type(data) == "table" and type(data.reports) == "table" then
					run.data, run.err, run.at = data, nil, os.time()
				else
					run.err = "omp beklenmeyen çıktı verdi: " .. first_line(result.stdout)
				end
			end
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

-- Yığılı görünüm: en az bu kadar sütun; bundan genişte yüzde ve süre sözcüklerle yazılır.
local ROOMY_MIN_COLS = 44
local ROOMY_WIDE_COLS = 64
-- Yığılı görünümde sağlayıcı grupları arasındaki ayraç, satır cinsinden.
local GROUP_GAP_LINES = 1

-- Blok satırları pane hücrelerinden ~%40 daha uzun; bölge kenar boşlukları ~2 hücre.
local ROW_CELLS = 1.4
local CHROME_CELLS = 2
-- Sütun genişlikleri, hücre: hesap etiketi, pencere başına kalan+sıfırlanma,
-- çubuk, yalnız kalan yüzdesi.
local ACCOUNT_COLS = 18
local WINDOW_COLS = 15
local BAR_COLS = 15
local PCT_COLS = 7
-- Bunun altında tablo yerine liste: etiket kırpılır, yüzdeler sağda kalır.
local TINY_COLS = 30
-- Durum satırındaki tuş ipucu bundan dar pane'de gösterilmez.
local HINT_COLS = 50

type Layout = {
	bars: boolean,
	resets: boolean,
	narrow: boolean,
	tiny: boolean,
	collapse: boolean,
	table_lines: number,
	capacity: number,
}

-- Kalan orana göre renk: biten kırmızı, %20 altı sarı, gerisi temanın vurgu rengi.
local function level_tone(left: number, status: string?): string?
	if left <= 0.0001 or status == "exhausted" then
		return "error"
	elseif left < 0.2 then
		return "warning"
	end
	return nil
end

local function remaining_spans(used: number, status: string?, suffix: string?): { Span | string }
	local left = 1 - used
	local tone = level_tone(left, status)
	return { ui.span(pct(left) .. (suffix or ""), if tone then tone .. " strong" else "strong") }
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
local function who(acc: Account): string
	local name = string.match(acc.label, "^([^@]+)@") or acc.label
	return if acc.org then name .. " · " .. acc.org else name
end

local function account_label(acc: Account, lead: { Span | string }, tone: string?): { Span | string }
	local spans = table.clone(lead)
	table.insert(spans, ui.span(who(acc), tone))
	if acc.resets > 0 then
		table.insert(spans, ui.span(string.format(" +%d sıfırlama", acc.resets), "success"))
	end
	return spans
end

-- Bir satırın pencere hücreleri: kalan, (çubuk), (sıfırlanma ya da toplam notu).
local function window_cells(row: { any }, layout: Layout, cell: Cell?, note: { Span | string }?)
	if cell == nil then
		table.insert(row, { ui.span("—", "dim") })
	else
		table.insert(row, remaining_spans(cell.used, cell.status))
	end
	if layout.bars then
		table.insert(row, if cell then remaining_meter_cell(cell) else "")
	end
	if layout.resets then
		table.insert(row, if cell then (note or { ui.span(until_text(cell.resets), "muted") }) else "")
	end
end

-- Birden çok hesabı olan sağlayıcının pencere toplamı: hesapların kalan
-- kotasının ortalaması, yani toplam kotanın kalan yüzdesi.
local function total_cell(prov: Provider, key: string): (Cell?, { Span | string }?)
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
	return { used = used / n }, { ui.span("toplam", "muted") }
end

-- Pane boyutuna göre ne sığar: dar pane'de önce çubuklar, sonra sıfırlanma
-- sütunları, en darda e-postalar düşer ve liste görünümüne geçilir; kısa ya da
-- çok dar pane'de çok hesaplı sağlayıcılar tek toplam satırına iner. Böylece
-- görünüm kaydırma istemez.
local function layout_for(providers: { Provider }, windows: number, extra_lines: number, cx: BlockCx): Layout
	local lines = 0
	for _, prov in providers do
		lines += if #prov.accounts > 1 then #prov.accounts + 1 else 1
	end
	local capacity = math.floor((cx.rows - CHROME_CELLS) / ROW_CELLS)
	local tiny = cx.cols < TINY_COLS
	local collapse = tiny or 1 + lines + extra_lines > capacity
	return {
		bars = cx.cols >= ACCOUNT_COLS + windows * (WINDOW_COLS + BAR_COLS),
		resets = cx.cols >= ACCOUNT_COLS + windows * WINDOW_COLS,
		narrow = cx.cols < ACCOUNT_COLS + windows * PCT_COLS,
		tiny = tiny,
		collapse = collapse,
		table_lines = 1 + (if collapse then #providers else lines),
		capacity = capacity,
	}
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
local function lines_of(providers: { Provider }, columns: { Column }, layout: Layout): { Line }
	local out: { Line } = {}
	for _, prov in providers do
		local name = provider_name(prov.id)
		if #prov.accounts == 1 then
			local acc = prov.accounts[1]
			local label = if layout.narrow
				then { ui.span(name, "strong") }
				else account_label(acc, { ui.span(name .. " ", "strong") }, "muted")
			table.insert(out, account_line(label, acc, columns))
		else
			local label: { Span | string } = { ui.span(name, "strong") }
			if not layout.narrow then
				table.insert(label, ui.span(string.format(" %d hesap", #prov.accounts), "muted"))
			end
			local total: Line = { label = label, cells = {}, notes = {} }
			for i, c in columns do
				local cell, note = total_cell(prov, c.key)
				total.cells[i] = cell
				total.notes[i] = note
			end
			table.insert(out, total)
			if not layout.collapse then
				for _, acc in prov.accounts do
					table.insert(out, account_line(account_label(acc, { ui.span("› ", "dim") }, nil), acc, columns))
				end
			end
		end
	end
	return out
end

-- Tablo: sütunlar en düşük öncelikten gizlenir (çubuk, sıfırlanma, sonraki
-- pencereler); etiket ve ilk pencere en son.
local function table_view(lines: { Line }, columns: { Column }, layout: Layout): Node
	local cols: { Col } = { { id = "account", head = "Hesap", grow = 1, truncate = "end", priority = 3 } }
	for i, c in columns do
		table.insert(cols, { id = "p" .. i, head = c.label, align = "end", priority = if i == 1 then 2 else 1 })
		if layout.bars then
			table.insert(cols, { id = "b" .. i, head = "", grow = 1, priority = -2 })
		end
		if layout.resets then
			table.insert(cols, { id = "r" .. i, head = "yenilenir", align = "end", priority = -1 })
		end
	end
	local rows: { { any } } = {}
	for _, line in lines do
		local row: { any } = { line.label }
		for i in columns do
			window_cells(row, layout, line.cells[i], line.notes[i])
		end
		table.insert(rows, row)
	end
	return with(ui.table(cols, rows), { key = "accounts" })
end

-- En dar pane: tablo etiketi taşıyamaz; liste etiketi kırpar, sığan kadar
-- pencerenin yüzdesi sağda kalır.
local function list_view(lines: { Line }, columns: { Column }, cx: BlockCx): Node
	local shown = math.clamp(math.floor((cx.cols - 9) / 5), 1, math.max(1, #columns))
	local heads: { string } = {}
	for i = 1, math.min(shown, #columns) do
		local short = string.gsub(string.gsub(columns[i].label, " saat", "s"), " gün", "g")
		table.insert(heads, short)
	end
	local items: { Item } = { { label = { ui.span("Hesap", "dim") }, value = { ui.span(table.concat(heads, " "), "dim") } } }
	for _, line in lines do
		local value: { Span | string } = {}
		for i = 1, math.min(shown, #columns) do
			if i > 1 then
				table.insert(value, " ")
			end
			local cell = line.cells[i]
			if cell then
				for _, s in remaining_spans(cell.used, cell.status) do
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
local function window_row(c: Column, cell: Cell?, wide: boolean, key: string): Node
	local name = with(ui.text({ ui.span(c.label, "muted") }), { min = { w = "8ch" } })
	if cell == nil then
		return with(ui.row({ name, ui.text({ ui.span("raporlanmadı", "dim") }) }), { key = key, role = "omp-usage.window" })
	end
	local left = 1 - cell.used
	local meter: { [string]: any } = { value = left, size = "md", grow = 1 }
	meter.tone = level_tone(left, cell.status)
	local reset = until_text(cell.resets)
	return with(ui.row({
		name,
		with(ui.text(remaining_spans(cell.used, cell.status, if wide then " kaldı" else nil)), {
			min = { w = if wide then "10ch" else "5ch" },
		}),
		ui.node("meter", meter),
		with(ui.text({ ui.span(if wide then reset .. " sonra yenilenir" else reset, "muted") }), {
			min = { w = if wide then "23ch" else "8ch" },
		}),
	}), { key = key, role = "omp-usage.window" })
end

-- Sağlayıcı başlığı: tek hesapta hesap adı, çok hesapta hesap sayısı ve
-- pencere başına toplam kalan.
local function provider_header(prov: Provider, columns: { Column }): Node
	local spans: { Span | string } = { ui.span(provider_name(prov.id), "strong") }
	if #prov.accounts == 1 then
		for _, s in account_label(prov.accounts[1], { ui.span(" · ", "dim") }, "muted") do
			table.insert(spans, s)
		end
	else
		table.insert(spans, ui.span(string.format(" · %d hesap", #prov.accounts), "muted"))
		local parts: { string } = {}
		for _, c in columns do
			local cell = total_cell(prov, c.key)
			if cell then
				table.insert(parts, c.label .. " " .. pct(1 - cell.used))
			end
		end
		if #parts > 0 then
			table.insert(spans, ui.span(" · toplam kalan " .. table.concat(parts, ", "), "muted"))
		end
	end
	return with(ui.text(spans), { key = "head", role = "omp-usage.provider" })
end

-- Yığılı görünümün satır sayısı (tablo satırı biriminde).
local function roomy_lines(providers: { Provider }, windows: number, status_count: number): number
	local n = 0
	for _, prov in providers do
		local k = #prov.accounts
		n += if k == 1 then 1 + windows else 1 + k * (1 + windows)
	end
	return n + (#providers - 1) * GROUP_GAP_LINES + status_count
end

-- Boş alanı okunabilirliğe harcayan görünüm: sağlayıcı grupları ayraçla
-- ayrılır, her hesabın her penceresi kendi çubuğuyla bir satır. Sığmazsa nil.
local function roomy_view(providers: { Provider }, columns: { Column }, status: { Node }, cx: BlockCx): { Node }?
	if cx.cols < ROOMY_MIN_COLS then
		return nil
	end
	if CHROME_CELLS + roomy_lines(providers, #columns, #status) * ROW_CELLS > cx.rows then
		return nil
	end
	local wide = cx.cols >= ROOMY_WIDE_COLS
	local children: { Node } = {}
	for gi, prov in providers do
		if gi > 1 then
			table.insert(children, with(ui.rule(""), { key = "rule:" .. prov.id }))
		end
		local group: { Node } = { provider_header(prov, columns) }
		for ai, acc in prov.accounts do
			if #prov.accounts > 1 then
				table.insert(group, with(ui.text(account_label(acc, {}, nil)), { key = "a" .. ai, role = "omp-usage.account" }))
			end
			for wi, c in columns do
				table.insert(group, window_row(c, acc.windows[c.key], wide, string.format("a%dw%d", ai, wi)))
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
local function accounts_view(providers: { Provider }, status: { Node }, cx: BlockCx): { Node }
	local columns = columns_of(providers)
	local roomy = roomy_view(providers, columns, status, cx)
	if roomy then
		return roomy
	end
	local layout = layout_for(providers, #columns, #status, cx)
	local lines = lines_of(providers, columns, layout)
	local body = if layout.tiny then list_view(lines, columns, cx) else table_view(lines, columns, layout)
	local children: { Node } = { body }
	-- Yer yoksa sade durum satırı düşer; sorun satırı her zaman kalır.
	local room = layout.capacity - layout.table_lines
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

-- Tablonun altındaki durum satırı; sorun varsa ikinci satır (profil hatası ya
-- da devre dışı hesap). Dock yerine ana bölgede: dock pane'in alt kenarında kırpılıyor.
local function status_lines(state: State, issues: { Issue }): { Node }
	local status: { Span | string } = { ui.span(string.format("%d profil", #state.order), "muted") }
	if state.loading then
		table.insert(status, ui.span(" · yenileniyor…", "muted"))
	elseif state.fetched then
		table.insert(status, ui.span(" · güncellendi " .. os.date("%H:%M", state.fetched), "muted"))
	end
	-- Dar pane'de ipucu satırı kaydırmasın diye düşer.
	if state.cx.cols >= HINT_COLS then
		table.insert(status, ui.span(" · r: yenile", "dim"))
	end
	local lines: { Node } = { with(ui.text(status), { key = "status" }) }

	local problems: { string } = {}
	for _, name in state.order do
		local run = state.profiles[name]
		if run and run.err then
			table.insert(problems, name .. ": " .. run.err)
		end
	end
	for _, it in issues do
		table.insert(problems, provider_name(it.provider) .. " " .. it.who .. ": " .. it.text)
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

local function count_accounts(state: State): number
	local providers = aggregate(state)
	local n = 0
	for _, p in providers do
		n += #p.accounts
	end
	return n
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
			timer = nil,
			ticks = 0,
		}
		running[cx.pane] = state
		refresh(state)
		schedule(state)
		return state
	end,

	title = function(state: State): string?
		if not has_data(state) then
			return "omp kullanım"
		end
		return string.format("omp kullanım · %d hesap", count_accounts(state))
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if not has_data(state) then
			local main: Node
			if state.loading or not state.fetched then
				main = ui.progress(nil, "omp profillerinden kullanım alınıyor…")
			elseif #state.order == 0 then
				main = ui.md("Hiç omp profili bulunamadı (`~/.omp/agent` ya da `~/.omp/profiles/*`). **r** ile tekrar dene.")
			else
				main = ui.md("Hiçbir profilden kullanım alınamadı; ayrıntılar aşağıda. **r** ile tekrar dene.")
			end
			local children: { Node } = { main }
			for _, line in status_lines(state, {}) do
				table.insert(children, line)
			end
			return { main = ui.col(children) }
		end
		local providers, issues = aggregate(state)
		return { main = ui.col(accounts_view(providers, status_lines(state, issues), state.cx)) }
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
		else
			return false
		end
		return true
	end,
})
