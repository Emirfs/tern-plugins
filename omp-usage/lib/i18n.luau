--!strict
-- Arayüz dili, Türkçe ya da İngilizce. Seçim `tern.kv` içinde ("lang") durur;
-- bloğun (host) `l` tuşu ve pencerenin palet komutu ikisi de okur/yazar.
-- Seçim yoksa yerel ayar: `tr*` Türkçe, başka her şey (ya da boş) İngilizce.
-- Modül saf: kv ve ortam değişkenlerini çağıran okur, buraya değerleri verir.

export type Lang = "tr" | "en"

local STR: { [string]: { [string]: string } } = {
	tr = {
		title = "omp kullanım",
		title_count = "omp kullanım · %d hesap",
		pct = "%%%d",
		-- pencere adları; kısa biçim dar listede
		hours = "%d saat",
		days = "%d gün",
		hours_short = "%ds",
		days_short = "%dg",
		-- yenilenmeye kalan süre
		until_now = "şimdi",
		until_lt_min = "<1dk",
		until_min = "%ddk",
		until_hour = "%dsa%02ddk",
		until_day = "%dg%02dsa",
		-- toplama
		unknown_account = "bilinmeyen hesap",
		issue_no_report = "kullanım raporu yok",
		issue_disabled = "devre dışı: %s",
		-- omp çalıştırma hataları
		err_not_found = "omp bu makinenin PATH'inde bulunamadı",
		err_spawn = "omp başlatılamadı: %s",
		err_none = "sonuç yok",
		err_timeout = "omp 60 saniyede yanıt vermedi",
		err_status = "omp çıkış kodu %d: %s",
		err_output = "omp beklenmeyen çıktı verdi: %s",
		stale = "%s verisi gösteriliyor",
		-- görünüm
		resets_credit = " +%d sıfırlama",
		total = "toplam",
		n_accounts = " %d hesap",
		col_account = "Hesap",
		col_resets = "yenilenir",
		not_reported = "raporlanmadı",
		left = " kaldı",
		resets_in = "%s sonra yenilenir",
		total_left = " · toplam kalan %s",
		profiles = "%d profil",
		refreshing = " · yenileniyor…",
		updated = " · güncellendi %s",
		cached = " (önbellek)",
		hint = " · r: yenile · l: EN",
		loading = "omp profillerinden kullanım alınıyor…",
		no_profiles = "Hiç omp profili bulunamadı (`~/.omp/agent` ya da `~/.omp/profiles/*`). **r** ile tekrar dene.",
		none_read = "Hiçbir profilden kullanım alınamadı; ayrıntılar aşağıda. **r** ile tekrar dene.",
		-- pencere yarısı
		cmd_open = "omp kullanımını aç (tüm hesaplar)",
		cmd_lang = "omp kullanım: dili değiştir (TR/EN)",
		lang_switched = "omp kullanım dili: Türkçe",
		not_loaded = "omp kullanım bloğu bu host'ta yüklü değil",
		not_loaded_detail = "`tern plugin list` ile eklentinin durumuna bak.",
	},
	en = {
		title = "omp usage",
		title_count = "omp usage · %d accounts",
		pct = "%d%%",
		hours = "%d hours",
		days = "%d days",
		hours_short = "%dh",
		days_short = "%dd",
		until_now = "now",
		until_lt_min = "<1m",
		until_min = "%dm",
		until_hour = "%dh%02dm",
		until_day = "%dd%02dh",
		unknown_account = "unknown account",
		issue_no_report = "no usage report",
		issue_disabled = "disabled: %s",
		err_not_found = "omp is not on this machine's PATH",
		err_spawn = "omp failed to start: %s",
		err_none = "no result",
		err_timeout = "omp did not answer within 60 seconds",
		err_status = "omp exited with %d: %s",
		err_output = "unexpected omp output: %s",
		stale = "showing data from %s",
		resets_credit = " +%d resets",
		total = "total",
		n_accounts = " %d accounts",
		col_account = "Account",
		col_resets = "resets",
		not_reported = "not reported",
		left = " left",
		resets_in = "resets in %s",
		total_left = " · total left %s",
		profiles = "%d profiles",
		refreshing = " · refreshing…",
		updated = " · updated %s",
		cached = " (cached)",
		hint = " · r: refresh · l: TR",
		loading = "Reading usage from omp profiles…",
		no_profiles = "No omp profile found (`~/.omp/agent` or `~/.omp/profiles/*`). Press **r** to retry.",
		none_read = "No profile returned usage; details below. Press **r** to retry.",
		cmd_open = "Open omp usage (all accounts)",
		cmd_lang = "omp usage: switch language (TR/EN)",
		lang_switched = "omp usage language: English",
		not_loaded = "The omp usage block is not loaded on this host",
		not_loaded_detail = "Check the plugin with `tern plugin list`.",
	},
}

local i18n = {}

i18n.KV_KEY = "lang"

--- Kayıtlı seçim (`saved`), yoksa yerel ayar (`LC_ALL`/`LC_MESSAGES`/`LANG` değeri).
function i18n.detect(saved: any, locale: string?): Lang
	if saved == "tr" or saved == "en" then
		return saved
	end
	if string.sub(string.lower(locale or ""), 1, 2) == "tr" then
		return "tr"
	end
	return "en"
end

function i18n.other(lang: Lang): Lang
	if lang == "tr" then
		return "en"
	end
	return "tr"
end

--- Geçerli dil, `rt` (Tern çalışma zamanı ya da test taklidi) üzerinden kv ve ortamı okuyarak.
function i18n.current(rt: any): Lang
	local ok, saved = pcall(rt.kv.get, i18n.KV_KEY)
	return i18n.detect(if ok then saved else nil, rt.getenv("LC_ALL") or rt.getenv("LC_MESSAGES") or rt.getenv("LANG"))
end

--- Dilin metin tablosu.
function i18n.strings(lang: Lang): { [string]: string }
	return STR[lang]
end

--- Her iki dilin blok başlığı: pencere açık bloğu başlığından tanır.
function i18n.titles(): { string }
	return { STR.tr.title, STR.en.title }
end

-- Testler iki dilin aynı anahtarları taşıdığını denetler.
i18n._STR = STR

return i18n
