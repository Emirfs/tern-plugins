# Todo · Jira

Mevcut Tern `~/TODO.md` panosunu kullanır; ayrı bir liste ve Jira kopyası oluşturmaz.
Python 3 gerekir. `tern plugin link <clone>/todo-jira` ile kurulur. Eklentinin veri dizinindeki
`config.json` içine `{"jira_url":"https://<site>.atlassian.net"}` yazın veya `TERN_JIRA_URL`
verin. Jira e-posta ve API anahtarı sırayla iki ayrı satırda `~/.jira_token.txt` dosyasından
okunur (`TERN_JIRA_CREDENTIAL_FILE` ile değişir). Anahtar eklenti ayarına, komut satırına veya
önizlemeye konmaz. `TERN_TODO_PATH` farklı bir yerel Markdown panosu seçer.

- **Jira’dan yenile**: bağlı hesaba atanmış kartları `Todo`, `Doing`, `Done` sütunlarına alır.
  Sonraki değişiklikleri ana pencere beş dakikada bir salt okunur Jira sorgusuyla alır.
- **Değişiklikler**: panoda değişen başlık, termin veya durum için hedefi ve değeri gösterir.
  Durum için Jira’nın o an izin verdiği geçişi seçin. Her alan ancak **Jira’ya gönder** ile yazılır.
  İki tarafta değişen alanlar ezilmez; bunu çözmek için panodaki alanı bildirilen Jira değerine
  getirin ve gerekiyorsa düzenlemeyi yeniden yapın. Sütun içi sıra, yerel etiketler ve notlar
  Jira’ya gönderilmez. Kartı yerelde silmek Jira kartını silmez; atama kapsamı dışında kalan
  kartın yerel notlarına dokunulmaz.
- **AI’a ata / Kanban’a ekle**: yerel veya bağlı TODO kartını seçin, Hermes panosunu ve
  isteğe bağlı AI profilini seçin. Hermes, onaylanan atamayı kendi yürütür; atamasız kart
  panoya eklenir. Hermes'in mevcut Kanban bildirim akışı geçerlidir.
- **Değişiklikler** ve **Doldur**: Mnemo’nun salt okunur indeksindeki etkin, doğrulanmış,
  tek bir atanmış karta tam Jira anahtarıyla bağlanan notlardan kart başına en güncel kısa
  özeti gösterir. Arka plan yalnızca öneri sayısını gösterir; öneri metni Tern seçicisinde
  görünür. **Doldur · Bu metni Jira’ya gönder** tam önizlenen metni kartın ilerleme yorumu
  olarak ekler, açıklama veya durumu değiştirmez. Özel sohbetler ve ham hafıza metinleri
  taranmaz. İndeks yolu `config.json` içindeki `memory_index` veya `TERN_TODO_MEMORY_INDEX`
  ile seçilebilir; varsayılan `~/GitHub/araclar/mnemo-vault/.mnemo/index.sqlite`.
  Carly’ye **doldur** demek de özel önizlemeyi açar; ayrıca seçicide onay vermeden yazmaz.
  Öneriye girmesi gereken iş notunda tam Jira anahtarını başlığa veya kısa özete yazın;
  yalnızca `verification: verified` olarak kaydedilmiş notlar önerilir.

Canlı Jira ve Hermes’e yazmadan doğrulama: `python -B -m unittest discover -s todo-jira/tests`.
