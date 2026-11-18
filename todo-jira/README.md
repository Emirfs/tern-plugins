# Todo · Jira

Mevcut Tern `~/TODO.md` panosunu kullanır; ayrı bir liste ve Jira kopyası oluşturmaz.
Python 3 gerekir. `tern plugin link <clone>/todo-jira` ile kurulur. Eklentinin veri dizinindeki
`config.json` içine `{"jira_url":"https://<site>.atlassian.net"}` yazın veya `TERN_JIRA_URL`
verin. Jira e-posta ve API anahtarı sırayla iki ayrı satırda `~/.jira_token.txt` dosyasından
okunur (`TERN_JIRA_CREDENTIAL_FILE` ile değişir). Anahtar eklenti ayarına, komut satırına veya
önizlemeye konmaz. `TERN_TODO_PATH` farklı bir yerel Markdown panosu seçer.

- **Jira paneli (kartlar ve yorumlar)**: bu hesaba atanmış kartları ve her kartın bütün
  yorumlarını (yazar, tarih, Markdown metin; senin yorumların “sen” ile işaretli, en yenisi üstte)
  ayrı bir pane'de gösterir. Salt okunurdur, beş dakikada bir ve `r` ile yenilenir; `d` biten
  kartları gösterir, `enter` veya çift tık kartı Jira'da açar. Satıra sağ tık: **AI’a ver**
  (aşağıdaki Kanban akışını o kartla açar), **Jira’da aç**, **Bağlantıyı kopyala**.
- **Jira’dan yenile**: bağlı hesaba atanmış kartları `Todo`, `Doing`, `Done` sütunlarına alır.
  Sonraki değişiklikleri ana pencere beş dakikada bir Jira'dan okuyup panoya işler; bu arka plan
  eşitlemesi durursa hata bir kez bildirilir.
- **Değişiklikler**: panoda değişen başlık, termin veya durum için hedefi ve değeri gösterir.
  Durum için Jira’nın o an izin verdiği geçişi seçin. Her alan ancak **Jira’ya gönder** ile yazılır.
  İki tarafta değişen alanlar ezilmez; bunu çözmek için panodaki alanı bildirilen Jira değerine
  getirin ve gerekiyorsa düzenlemeyi yeniden yapın. Sütun içi sıra, yerel etiketler ve notlar
  Jira’ya gönderilmez. Kartı yerelde silmek Jira kartını silmez; atama kapsamı dışında kalan
  kartın yerel notlarına dokunulmaz.
- **AI’a ata / Kanban’a ekle**: yerel veya bağlı TODO kartını seçin (ya da Jira panelinde sağ tık
  **AI’a ver**), isteğe bağlı AI profilini seçin; tek Hermes panosu varsa pano sorulmaz. Jira
  kartında göreve kartın Jira'daki açıklaması ve son üç yorumu eklenir. Hermes, onaylanan atamayı
  kendi yürütür; atamasız kart panoya eklenir. Aynı kart, profil ve bağlam için Hermes yeni görev
  açmaz, mevcut görevi döndürür; bildirim o görevin durumunu söyler.
- **Hafıza kasası**: her eşitlemede atanmış her kart için ortak hafıza kasasında
  `jira/<KEY>.md` notu tutulur (varsayılan `~/GitHub/araclar/hafiza`; `config.json` içinde `vault`
  ya da `TERN_HAFIZA_DIR`). Eklenti yalnız frontmatter'ı ve **Sent to Jira** bölümünü (Jira'daki
  yorumların) Jira'dan yeniden yazar; Summary, Log, Open, Decisions ve Jira draft bölümleri senin ve
  ajanlarındır, dokunulmaz. Değişen notlar kasa bir git deposuysa tek commit'le kaydedilir. Jira
  panelinde kartın dolu bölümleri görünür; sağ tık **Hafıza notunu aç** dosyayı açar.
- **Değişiklikler** ve **Doldur**: notun **Jira draft** bölümü doluysa o metin (Markdown) kartın
  ilerleme yorumu olarak önerilir. **Doldur · Bu metni Jira’ya gönder** onaydan sonra Jira'ya
  ekler, açıklamayı veya durumu değiştirmez; aynı metin zaten varsa tekrar göndermez. Gönderilen
  taslak notta temizlenir ve **Sent to Jira** listesine geçer. Carly’ye **doldur** demek de
  önizlemeyi açar; seçicide onay vermeden yazmaz.

Canlı Jira ve Hermes’e yazmadan doğrulama: `python -B -m unittest discover -s todo-jira/tests`.
