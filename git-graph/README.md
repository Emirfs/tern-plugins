# Git grafiği

Bir deponun commit grafiği Tern paneli olarak: her dal kendi renkli şeridinde (birleşmeler halka, HEAD dolu
halka), seçili commit'in mesajı, ebeveynleri ve değişen dosyaları, bir dosyanın diff'i grafiğin üstünde.
Fikir [mykeura/git-gui](https://github.com/mykeura/git-gui)'den; `git` PATH'te olmalı.

## Açmak

| Komut | Ne yapar |
|---|---|
| **Git grafiği: yeni panel** | Odaktaki terminalin (ya da omp/agent panesinin) deposunu izler; odak başka depoya geçince grafik de geçer |
| **Git grafiği: bu klasörün deposu (sabit)** | Odaktaki terminalin deposunu sabitler |
| **Git grafiği: depo seç** | `~/GitHub` altındaki bütün depolardan yazarak süzüp seçer |

Her komut yeni bir pane açar: birden çok depo yan yana açılabilir, pane'ler taşınabilir ve park edilebilir.
Panede **Depolar** (`o`) aynı seçiciyi açar, **Sabitle / Odağı izle** (`p`) izleme ile sabit arasında geçer.

## Kullanım

- **Grafik**: `◉` HEAD, `○` birleşme, `●` commit. Dal etiketleri mesajın önünde: geçerli dal vurgulu,
  `☁` uzak dal, `⌂` etiket. **Uzak dallar** (`u`) uzak dalları da çizer. İlk 400 commit okunur, tablonun
  sonundaki düğme sonrakileri yükler.
- **Ayrıntı** (alt bölüm): mesajın gövdesi, yazar, tarih, ebeveynler (tıklayınca o commit'e gider), mesajdaki
  Jira anahtarları, değişen dosyalar. Birleşmelerde dosyalar ilk ebeveyne göredir (PR'ın getirdikleri).
- **Diff**: dosyaya çift tık ya da `enter`; `[` `]` dosyalar arasında gezer, `esc` kapatır.
- **Sağ tık** bir commit'te: hash'i kopyala, web'de aç (GitHub/GitLab), buradan dal aç, AI'a açıklat, o
  commit'teki dallara geç, Jira kartını ve kasadaki kart notunu aç.
- **Tuşlar**: `↑` `↓` / `j` `k` commit, `r` yenile, `f` fetch, `c` hash kopyala, `w` web, `b` dal aç, `a` AI.
- Pane 15 saniyede bir dalların ve HEAD'in yerine bakar; geçmişi yalnız bir şey kıpırdadıysa yeniden okur.

## Ne yazar

Yalnız senin başlattığın güvenli işler:

- **Dala geç**: çalışma ağacında kaydedilmemiş değişiklik varsa reddeder; yoksa onay sorar, sonra
  `git switch` (uzak dal için `git switch --track`).
- **Dal aç**: adı sorar, `git check-ref-format` ile doğrular, `git branch <ad> <commit>` (dala geçmez).
- **Fetch**: `git fetch --all`; parola sorulmaz (`GIT_TERMINAL_PROMPT=0`).

Commit, push, reset, merge ya da silme yapmaz.

## AI açıklaması

**AI'a açıklat** commit'in mesajını, istatistiğini ve diff'ini (en çok 12 000 karakter) ucuz modele verir ve
en çok 5 maddelik Türkçe özeti ayrıntıda gösterir. Varsayılan: `omp -p --no-tools … --model haiku`; araç,
oturum, kural ve bağlam dosyası yüklenmez. Sonuç commit başına saklanır, aynı commit için tekrar harcamaz.

## Ayarlar

Eklentinin veri klasöründeki `config.json` (Windows'ta `%LOCALAPPDATA%\Tern\plugin-data\git-graph\`), hepsi
isteğe bağlı:

```json
{
  "roots": ["C:\\Users\\me\\GitHub"],
  "depth": 4,
  "jira_url": "https://inohom64.atlassian.net",
  "jira_projects": ["FRMWR"],
  "vault": "C:\\Users\\me\\GitHub\\araclar\\hafiza",
  "ai_argv": ["omp", "-p", "--no-tools", "--model", "haiku"]
}
```

- `roots`, `depth`: **Depolar** seçicisinin taradığı klasörler ve derinlik (`node_modules`, `.venv`, gizli
  klasörler atlanır; bir deponun içine inilmez).
- `jira_projects`: yalnız bu projelerin anahtarları kart sayılır (`UTF-8`, `SHA-256` sayılmaz).
- `vault`: kart notu `jira/<KEY>.md` ve proje notu `projects/<depo>.md` buradan açılır.

## Test

```sh
lune run git-graph/tests/run.luau
```

Şerit yerleşimi, ayrıştırıcılar, geçici bir depoda gerçek git ile komutlar ve paneli taklit çalışma
zamanında uçtan uca (dala geçme onayı, kirli ağaçta ret, odak izleme, AI önbelleği) dener.
