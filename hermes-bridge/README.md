# hermes-bridge

Carly, Hermes ve omp arasında köprü (yalnız pencere yarısı, `window.luau`).

## Carly'ye verdikleri (`plugins['hermes-bridge']`)

| Export | Ne yapar |
| --- | --- |
| `hermes_ask(prompt, profile?)` | `hermes [-p profile] -z prompt`, son yanıt metni (≤ 2 dk) |
| `hermes_kanban(title, body?, assignee?)` | `hermes kanban create --json --created-by carly …`; bildirimleri Hermes merkezden atar |
| `esp_list()` | `hermes tern --list-devices` (C1) |
| `esp_open(device)` | "ESP" oturumunda cihazın sekmesini açar ya da odaklar (`hermes tern --device <id>`, sekme adı = cihaz adı) |
| `omp_start(prompt, cwd?, command?)` | `cx.agents:start{how='tab'}` |
| `agents_list()` | `cx.agents:list()` özeti |

Bağlam satırı (`tern.carly.context`, ≤ 400 karakter): `gateway_state.json` platform durumları ve
cihaz listesi. Sağlayıcı yalnız hazır metni döndürür (4 ms bütçesi); metni dakikada bir zamanlayıcı
yeniler, cihaz listesini lider pencere 5 dakikada bir `hermes tern --list-devices` ile çeker
(`tern.kv` `devices`).

## `tern-bridge` kuyruğu

`tern-bridge` (Python stdlib) `%LOCALAPPDATA%\Tern\plugin-data\hermes-bridge\spool\<id>.json` yazar
(önce `.tmp`, sonra yeniden adlandırma; `TERN_BRIDGE_SPOOL` değiştirir). Tek bir pencere (kv `leader`
kalp atışı) 2 sn'de bir işleri alır: dosyayı siler, çalıştırır, sonucu `done/` ya da `failed/`
(nedenle) altına yazar; her biri en çok 200 kayıt tutar.

```
tern-bridge carly TEXT...                 # cx:ask_carly
tern-bridge omp [--cwd DIR] [--command C] [--how tab|split|replace_if_alone] PROMPT...
tern-bridge esp DEVICE                    # esp_open
tern-bridge notify [--level info|success|error] [--title T] TEXT...   # toast
tern-bridge read --title T --key KEY [--from NAME] (PATH | -)          # okuma sekmesi
tern-bridge status [--json]               # bekleyen / başarısız / son işler
```

`-` metni stdin'den okur, `--from NAME` göndereni yazar, `--wait N` sonucu bekler (çıkış 0 tamam,
1 başarısız, 2 hâlâ bekliyor: Tern ya da eklenti çalışmıyor).

`read`: Markdown dosyasını kullanıcının o an baktığı oturumda yeni, mavi bir sekmede açar (sekme adı `T`)
ve kısa bir bilgi bildirimi gösterir; sekmeyi kapatmak = okundu. `-` stdin'i
(≤ 200 KB) `plugin-data\hermes-bridge\reading\<YYYYMMDD-HHMMSS>-<slug>.md` altına yazar (spool'un
kardeşi), iş o yolu taşır; PATH de ≤ 200 KB olmalı. Aynı `KEY` bir kez açılır (kv `read_seen`, son 500
anahtar; tekrar `done/` altına `duplicate = true` ile düşer). `cx.docs:open`'ın odak seçeneği yok:
açtıktan sonra kullanıcının odaklı bölmesi geri getirilir, sekme sekme çubuğunda bekler. Üreticiler: Hermes cron
`hafiza_collect.py` (günlük not yazılıp oturunca `daily-<tarih>`), cihaz ajanları, hafıza önerileri,
kanban.

Kurulum: `cli\install.cmd` → `%USERPROFILE%\.local\bin\tern-bridge.cmd` + `tern_bridge.py`
(kullanıcı PATH'inde).

Yetenekler: Hermes için `%LOCALAPPDATA%\hermes\skills\autonomous-ai-agents\tern-bridge\SKILL.md`, omp
(bütün profiller, `agents:user` kaynağı) için `~\.agents\skills\tern-bridge\SKILL.md`. İkisi de cihaza
yazan işleri ve kullanıcı adına mesaj göndermeyi açık onay olmadan yasaklar.

## Test

```sh
lune run hermes-bridge/tests/run.luau
python hermes-bridge/tests/test_cli.py
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau hermes-bridge/*.luau hermes-bridge/lib/*.luau
```

`tests/window_stub.luau`, `window.luau`yı Tern olmadan çalıştırır (exportlar, kuyruk, lider, ESP sekmesi).
