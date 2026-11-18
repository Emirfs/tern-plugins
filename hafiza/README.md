# Hafıza

Ortak hafıza kasasının (`~/GitHub/araclar/hafiza`, `HAFIZA_DIR` ile değişir) Tern paneli. Python 3 gerekir;
kasaya yazan her şey kasanın kendi `.tools/inbox.py` aracıdır, panel kasaya doğrudan yazmaz.

- **Hafıza: öneriler ve bugün** komutu paneli açar ya da açıksa odaklar.
- **Öneriler**: ajanların `memory_write op=propose` ile bıraktıkları (özet, karar, ders, profil, kural fikri, açık iş).
  Seçili öneride metin, neden ve kaynak görünür. **Kabul et** (`a`) öneriyi hedef notuna işler ve commit eder;
  **Reddet** (`x`) öneriyi siler (git geçmişinde kalır). Sağ tık **Hedef notu aç** notu açar.
- Kural fikirleri kural dosyalarına otomatik gitmez: kabul edilirse kasada `rules-accepted.md`'ye yazılır,
  agent-rules'a elle taşınır.
- **Bugün**: kasanın `daily/<bugün>.md` notu; toplayıcı her akşam 20:30'da doldurur.
- Panel dakikada bir ve `r` ile yenilenir.
