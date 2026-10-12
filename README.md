# Üçlü Tahmin Ligi

Arkadaşlar arasında Fenerbahçe, Galatasaray ve Beşiktaş maçlarının (lig ve Avrupa) skor tahmini oyunu. Herkes adını yazıp tahmin girer, sonuçlar girilince puanlanır ve sıralama güncellenir.

Canlı site: https://tahmin-ligi-render.onrender.com/

## Nasıl çalışır

- **Üyelik: kullanıcı adı + şifre.** Tahmin girmek ve sohbet için giriş yapmak gerekir (bkz. "Üyelik"). Misafirler maçları, tahminleri, sıralamayı ve sohbeti okuyabilir ama yazamaz.
- **Her maça tek tahmin.** Kaydedilince kilitlenir, değiştirilemez, silinemez (yönetici hariç).
- **Maçtan 5 saat önce kapanır.** Örneğin 20:00'de başlayan maça 15:00'e kadar tahmin girilir. Kural veritabanında uygulanır, tarayıcıdan atlatılamaz.
- **Herkesin tahmini maç kartında görünür.**
- **Maçlar sekmesi:** Canlı maçlar en üstte durur, altında **Oynanacak** ve **Oynanan** yan yana iki sekme vardır (parantez içinde maç sayısı). Biten maçta skorun altında **MS** (maç sonu) yazar.
- **Saatler Türkiye saatidir (TSİ).**

### Puanlama

| Durum | Puan |
|---|---|
| Skoru tam bildin | 5 |
| Galibi ve gol farkını bildin veya beraberliği bildin | 3 |
| Galibi bildin ama gol farkı yanlış | 2 |
| Yanlış | 0 |

**Beraberlikte** gol farkı her zaman 0 olduğu için, beraberliği bilen her tahmin (skor farklı olsa bile) 3 puan alır. 2 puanlık durum sadece galibiyet sonuçlarında vardır.

Skor 90 dakika + uzatma sonucudur, penaltılar sayılmaz.

| Gerçek skor | Tahmin | Puan | Neden |
|---|---|---|---|
| 2-1 | 2-1 | 5 | Skor tam |
| 2-1 | 3-2 veya 1-0 | 3 | Galip ve 1 gol farkı doğru |
| 2-1 | 3-0 | 2 | Galip doğru, fark yanlış (3 gol) |
| 2-1 | 1-1 veya 0-1 | 0 | Galip yanlış |
| 2-2 | 2-2 | 5 | Skor tam |
| 2-2 | 1-1 veya 0-0 | 3 | Beraberlik doğru, fark (0) doğru |
| 2-2 | 2-1 | 0 | Beraberlik tahmin edilmemiş |

## Mimari

```
Tarayıcı (index.html)  ──►  Supabase (Postgres + REST)  ◄──  Raspberry Pi (Python betikleri)
        ▲                                                         │
   Render (statik site)                                           ├─ bot.py (Telegram, sürekli servis)
                                                                  ├─ sync_fixtures.py (yeni maçlar, saatlik)
                                                                  ├─ live_scores.py (canlı skor, gol/kart olayları, kesin skor; sürekli servis)
                                                                  ├─ sync_standings.py (puan durumları, canlı, sürekli servis)
                                                                  └─ update_scores.py (uzatmalı/penaltılı maçların skoru, 2 dk'da bir)
```

| Parça | Ne yapar | Nerede |
|---|---|---|
| `index.html`, `config.js` | Site (tek sayfa, derleme yok) | Render (GitHub'dan otomatik yayın) |
| `schema.sql`, `seed.sql`, `bot.sql`, `telegram.sql` | Veritabanı tabloları, kurallar, fonksiyonlar, ilk maçlar | Supabase |
| `telegram-bot/bot.py` | Telegram: oyuncuyu bağlar, tahmin girmeyenlere hatırlatma atar | Raspberry Pi (systemd servisi) |
| `telegram-bot/sync_fixtures.py` | ESPN'den yeni maçları ekler | Raspberry Pi (cron) |
| `telegram-bot/live_scores.py` | Sürmekte olan maçların canlı skorunu, gol/kart olaylarını yazar, maç bitince kesin skoru girer | Raspberry Pi (systemd servisi: `tahmin-live`) |
| `telegram-bot/sync_standings.py` | Süper Lig ve Avrupa kupalarının puan durumunu ESPN'den çekip yazar (sitedeki **Süper Lig** ve **Avrupa** sekmeleri) | Raspberry Pi (servis: `tahmin-standings`) |
| `update_scores.py` | ESPN'den biten maçların skorunu yazar (`live_scores.py`'nin bırakmadığı uzatmalı/penaltılı maçlar için) | Raspberry Pi (cron), bu depoda yok |

### Veritabanı güvenliği

- Tablolara tarayıcıdan **doğrudan yazılamaz**. Maçlar ve tahminler herkese açık okunur, oyuncu listesi sadece ad ve kimlik gösterir (`players_public` görünümü).
- Yazma işlemleri yalnızca kontrollü fonksiyonlarla yapılır:
  - `player_login`, `submit_prediction`: oyuncu işlemleri (kapanış, tek tahmin kuralı burada).
  - `admin_*`: yönetici şifresi ister (maç ekle, skor gir/sil, maç sil).
  - `bot_*`: otomasyon anahtarı ister, sadece maç ekleme, boş skora skor yazma ve Telegram işlemlerine yetkilidir. Maç silemez.
- `config.js` içindeki **publishable** anahtar tarayıcıda görünmek üzere tasarlanmıştır. `secret` / `service_role` anahtarını, yönetici şifresini, otomasyon anahtarını ve Telegram token'ını **asla** depoya koyma.

## Kurulum

### 1. Supabase

1. supabase.com'da proje oluştur.
2. SQL Editor'de sırayla çalıştır: `schema.sql`, `seed.sql`, `bot.sql`, `telegram.sql`, `live.sql`, `extra.sql`, `events.sql`, `standings.sql`, `chat.sql`, **`chat_images.sql`** (sohbete fotoğraf ekleme), sonra **`members.sql`** (eski şifresiz giriş fonksiyonlarını siler ve üyelik sistemini kurar), en son **`telegram_link.sql`** (Telegram bağlantısını üyelik oturumuna bağlar).
3. Yönetici şifresini belirle (`BURAYA_SIFRE` yerine kendi şifren):

```sql
insert into admin_config (key, value)
values ('admin_hash', crypt('BURAYA_SIFRE', gen_salt('bf')))
on conflict (key) do update set value = excluded.value;
```

4. `bot.sql` içindeki yorum satırındaki örneğe göre otomasyon anahtarını belirle (uzun, rastgele bir metin).
5. Project Settings > API'den proje adresini ve **publishable** anahtarı al, `config.js`'e yaz.

### 2. Render (site)

New > Static Site > bu depoyu seç. Branch: `main`, Build Command: boş, Publish Directory: `.`. Her `git push` siteyi otomatik günceller.

### 3. Raspberry Pi (betikler)

`~/tahmin-bot` klasörü:

```bash
mkdir -p ~/tahmin-bot && cd ~/tahmin-bot
R=https://raw.githubusercontent.com/Alper-Yetik/tahmin-ligi-render/main/telegram-bot
curl -fsSLO $R/bot.py && curl -fsSLO $R/sync_fixtures.py && curl -fsSLO $R/tahmin-bot.service
curl -fsSL $R/config.example.json -o config.json
nano config.json        # token, supabase adresi/anahtarı ve otomasyon anahtarını doldur
chmod 600 config.json
python3 bot.py --check  # Telegram ve Supabase bağlantısını dener
```

**Telegram botu (sürekli servis, mesajlara anında cevap verir):**

```bash
sudo cp tahmin-bot.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now tahmin-bot
systemctl is-active tahmin-bot
```

**Yeni maç ekleme (saatte bir):**

```bash
python3 sync_fixtures.py --dry-run     # önce dene, hiçbir şey eklemez
(crontab -l 2>/dev/null; echo "7 * * * * /usr/bin/python3 /home/alper/tahmin-bot/sync_fixtures.py") | crontab -
```

> `raw.githubusercontent.com` dosyaları birkaç dakika önbellekte tutabilir. Yeni yayınlanan bir dosyayı hemen indireceksen adreste `main` yerine commit numarasını kullan.

## Sohbet

Sitedeki **Sohbet** sekmesinde oyuncular adlarıyla mesaj yazar (en fazla 300 karakter). Sayfa açıkken 4 saniyede bir yenilenir, başka sekmedeyken okunmamış mesaj sayısı sekmenin yanında görünür. Bir oyuncu 2 saniyede birden fazla, tüm sohbet dakikada 40'tan fazla mesaj yazamaz. Son 500 mesaj tutulur, eskileri otomatik silinir. Yönetici girişi yapınca her mesajın yanında "sil" bağlantısı çıkar.

Mesajlar gün gün gruplanır: günlerin arasında "Bugün", "Dün", "9 Eki Cum" gibi (Türkiye saatine göre) ayraç durur, her mesajın yanında saati yazar. Sohbeti kaydırırken o anki günün etiketi üstte yapışık kalır, yeni güne gelince eski günün etiketini yukarı iterek yerine geçer. Kaydırmayı bırakınca (yaklaşık 1,3 saniye sonra) sadece tepeye yapışmış etiket kaybolur, mesajların arasındaki ayraçlar yerinde kalır (WhatsApp gibi).

Mesaj yazmak için giriş yapmak gerekir, mesaj üyenin kendi adıyla görünür. Tablo (`chat_messages`) tarayıcıdan doğrudan yazılamaz, sadece oturum anahtarı isteyen `send_chat` fonksiyonuyla yazılır. Kurulum: `chat.sql`, `members.sql`.

**Fotoğraf:** Mesaj yazma kutusunun yanındaki resim düğmesiyle fotoğraf eklenebilir (yazı olmadan da gönderilir). Fotoğraf tarayıcıda küçültülür (en çok 1280 piksel, jpeg, yaklaşık 500 KB), Supabase Storage'daki herkese açık `chat-images` klasörüne rastgele bir adla yüklenir ve mesaja sadece bu ad yazılır. Sohbette küçük görünür, tıklayınca büyür. Yalnızca giriş yapmış üyeler `send_chat_image` fonksiyonuyla gönderebilir, dakikada en çok 10 fotoğraf sınırı vardır. Yönetici mesajı silince fotoğraf sohbetten kalkar ama dosya klasörde kalır (Supabase panelindeki Storage bölümünden elle silinebilir). Kurulum: `chat_images.sql`.

## Üyelik

- **Üye ol:** Kullanıcı adı (2-24 karakter) ve en az 6 karakterlik şifre. Şifre veritabanında bcrypt ile saklanır, geri okunamaz.
- **Giriş:** Başarılı girişte cihaza 60 günlük bir oturum anahtarı verilir (veritabanında sadece özeti saklanır). Tahmin ve sohbet işlemleri bu anahtarla yapılır, kullanıcı adı yazarak yapılamaz.
- **Kilitlenme:** 5 yanlış şifre ya da kod denemesinde hesap 15 dakika kilitlenir.
- **Şifre değiştirme:** Giriş yapmış üye "şifre değiştir" ile değiştirir, diğer cihazlardaki oturumları kapanır.
- **Çıkış yap:** Üstteki "çıkış yap" oturumu bu cihazda ve veritabanında kapatır. Çıkınca misafir görünümüne dönülür (okumak serbest, yazmak için giriş gerekir).
- **Eski (şifresiz) oyuncular ve şifresini unutanlar:** Yönetici girişi yapınca **Yönetim** sekmesindeki **Oyuncular** listesinden oyuncunun yanındaki "Kod üret" ya da "Şifreyi sıfırla" düğmesine basar. Çıkan tek kullanımlık kodu (örn. `A3F0-9C21`) oyuncuya iletir. Oyuncu **Kodum var** sekmesinde kullanıcı adı, kod ve yeni şifresiyle hesabını sahiplenir. Kod bir kez kullanılır, kodu yönetici sadece üretildiği anda görür.
- Telegram hatırlatması oturum anahtarına bağlıdır: üye giriş yapınca "Telegram'dan hatırlat"a basar, site 15 dakikalık tek kullanımlık kod üretir (bkz. "Telegram hatırlatması").

## Canlı puan durumu

- Raspberry'deki `live_scores.py` sürekli servis olarak (`tahmin-live`) çalışır, maç sürerken 20 saniyede bir kontrol eder. Başlamış ve henüz kesin skoru girilmemiş maçlar varsa ESPN'den anlık skoru ve dakikayı çeker, Supabase'e yazar (`live_home`, `live_away`, `live_minute`, `live_state`). Böyle bir maç yoksa hiçbir ağ isteği yapmadan çıkar.
- Site canlı maçı "Canlı maçlar" bölümünde kırmızı skor ve dakika ile gösterir, tahminlerin yanında **şimdilik** kazanılan puanı yazar ve **Sıralama** sekmesini şimdiki skora göre hesaplar. Canlı maç varken sayfa 15 saniyede bir yenilenir.
- **Kartlar:** Maç kartında her takımın adının üstünde sarı ve kırmızı kart sayısı görünür (kart yoksa hiçbir şey görünmez). Canlıyken güncellenir, maç bittikten sonra da kalır. Betik kartları ESPN'in maç olaylarından sayar.
- **Uzatma süresi:** Dördüncü hakem uzatmayı gösterince canlı maçta dakikanın altında "Uzatma: 4 dk" yazar. Bu bilgi ESPN'in maç yorumundaki "Fourth official has announced N minutes of added time" satırından okunur. Dakika `45+2'` gibi, uzatmada geçen süreyi gösterir.
- **Gol ve kart olayları:** Maç kartının altında, hangi oyuncunun gol attığı ya da kart gördüğü dakikasıyla listelenir (ev sahibi solda, deplasman sağda). Penaltı golü `(P)`, kendi kalesine gol `(k.k.)` ile işaretlenir. Veri ESPN'in maç olaylarından gelir, `live_scores.py` yazar. Kurulum: `events.sql`'i Supabase'de bir kez çalıştır, sonra Raspberry'deki `live_scores.py`'yi yenile.
- Canlı puanlar geçicidir. Maç normal sürede bitince `live_scores.py` kesin skoru kendisi yazar (uzatmalı/penaltılı maçları `update_scores.py`'ye ya da Yönetim sekmesine bırakır) ve puanlar kesinleşir. Canlı veri 10 dakikadır güncellenmediyse site onu canlı saymaz. Kesin skor hiç gelmezse maç "Oynanan maçlar"a geçer, son canlı skor "kesinleşmedi" notuyla gösterilir ve sıralamada sayılır.

```bash
cd ~/tahmin-bot && python3 live_scores.py --dry-run     # ne yazacağını gösterir
# Önerilen: sürekli servis, maç sürerken 20 saniyede bir kontrol eder
curl -fsSLO https://raw.githubusercontent.com/Alper-Yetik/tahmin-ligi-render/main/telegram-bot/tahmin-live.service
sudo cp tahmin-live.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tahmin-live
tail -20 ~/tahmin-bot/live.log
```

Servis kullanırsan cron'daki `live_scores.py` satırını kaldır (`crontab -e`), ikisi aynı anda çalışmasın. Cron ile en sık dakikada bir çalışır:
`* * * * * /usr/bin/flock -n /tmp/tahmin-live.lock /usr/bin/python3 /home/alper/tahmin-bot/live_scores.py`.
ESPN'in canlı verisi zaten yaklaşık 30-60 saniyede bir yenilenir, 20 saniyeden sık sormanın faydası yoktur.

## Puan durumları

Sitenin üstündeki **Süper Lig** ve **Avrupa** sekmeleri güncel puan durumunu gösterir. Avrupa sekmesinde Şampiyonlar Ligi, Avrupa Ligi ve Konferans Ligi arasında geçiş yapılır (açılışta Şampiyonlar Ligi). Fenerbahçe, Galatasaray ve Beşiktaş satırları vurgulanır, renkli şeritler ve altındaki açıklama (Şampiyonlar Ligi, play-off, küme düşme vb.) ESPN'den gelir. Telefonda A/Y (atılan/yenilen gol) sütunları gizlenir.

Veriyi Raspberry'deki `sync_standings.py` ESPN'den çeker ve Supabase'deki `standings` tablosuna yazar. Sürekli servis olarak (`tahmin-standings`) çalışır: maç sürerken 30 saniyede bir, maç yokken 2 dakikada bir bakar ve sadece değişen tabloyu yazar.

**Canlı puan durumu:** ESPN'in resmi tablosu ancak maç bitince güncellenir. Bu yüzden betik, ligde oynanan maçların anlık skorlarını resmi tablonun üstüne uygular ("maç şu skorla biterse tablo böyle olur"). Etkilenen takımların satırında "● CANLI" ve anlık skor görünür. Resmi tablo maçı içerince canlı hesap kendiliğinden bırakılır. Sıralama puan, averaj ve atılan gole göre yapılır (Süper Lig'in ikili averaj gibi ayrıntılı kuralları uygulanmaz, bu yüzden eşit puanda küçük fark olabilir). Eleme turu maçları lig tablosunu etkilemez. Sayfa Süper Lig/Avrupa sekmesi açıkken tabloyu canlı maçta 15 saniyede bir yeniler.

Kurulum: `standings.sql`'i Supabase'de bir kez çalıştır, sonra:

```bash
cd ~/tahmin-bot
curl -fsSLO https://raw.githubusercontent.com/Alper-Yetik/tahmin-ligi-render/main/telegram-bot/sync_standings.py
curl -fsSLO https://raw.githubusercontent.com/Alper-Yetik/tahmin-ligi-render/main/telegram-bot/tahmin-standings.service
python3 sync_standings.py --dry-run     # önce dene, hiçbir şey yazmaz
sudo cp tahmin-standings.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tahmin-standings
tail -20 ~/tahmin-bot/standings.log
```

Daha önce saatlik cron satırı eklediysen kaldır (`crontab -e`), ikisi aynı anda çalışmasın.

Sezon yılı otomatik bulunur (Temmuz'dan itibaren yeni sezon). Takım adları ESPN'de İngilizce harfle gelir, `sync_standings.py` içindeki `NAMES` listesinde olanlar Türkçe yazılır (ör. Kasimpasa → Kasımpaşa), eksik olanı oraya ekleyebilirsin.

## Telegram hatırlatması

1. Üye siteye giriş yapar, üstteki **"Telegram'dan hatırlat"** bağlantısına tıklar ve botta **Başlat**'a basar. Site, giriş yapmış üyenin oturum anahtarıyla **15 dakika geçerli, tek kullanımlık bir kod** üretir ve botu o kodla açar (`t.me/uclu_tahmin_bot?start=<kod>`). Bot kodu veritabanına gönderir, kod sadece o üyeyi bağlar. Oyuncu kimliğini bilmek yetmez. Kurulum: `telegram_link.sql`. Kodu bot'a verilen eski (oyuncu kimliğiyle bağlayan) fonksiyon, botu güncelledikten sonra `drop function if exists bot_link_telegram(text, uuid, bigint);` ile silinir.
2. Bir maçın tahmin kapanışına **3 saat kala** (maçtan 8 saat önce), tahmin girmemiş ve Telegram'ı bağlamış oyunculara bot özel mesaj atar. Aynı maç için bir kez.
3. Girenlere ve bağlamayanlara mesaj gitmez.

Bot kullanıcı adı: `@uclu_tahmin_bot`.

## Yönetim

Sayfanın altındaki **Yönetici girişi** ile şifreyi girince **Yönetim** sekmesi açılır: maç ekle, skor gir/sil, maç sil. Normalde skorları ve yeni maçları betikler girer, burası yanlış ya da eksik olduğunda elle düzeltmek içindir.

## Günlük kontrol komutları (Raspberry Pi)

```bash
tail -20 ~/tahmin-bot/bot.log           # bot: gelen mesajlar, gönderilen hatırlatmalar
tail -20 ~/tahmin-bot/fixtures.log      # yeni eklenen maçlar
tail -20 ~/tahmin-ligi/log.txt          # skor betiği
journalctl -u tahmin-bot -n 20 --no-pager
journalctl -u tahmin-live -n 20 --no-pager   # canlı skor servisi
tail -20 ~/tahmin-bot/live.log          # canlı skor: yazılan skor, olay ve kesin skor satırları
sudo systemctl restart tahmin-bot       # bot kodunu güncelledikten sonra
crontab -l                              # zamanlanmış işler
```

## Sorun giderme

| Belirti | Olası neden |
|---|---|
| Bot cevap vermiyor | `systemctl is-active tahmin-bot` ve `bot.log`'a bak. Eski cron satırı varsa kaldır (iki süreç aynı anda mesaj okuyamaz). |
| "Telegram'dan hatırlat" bağlantısı çıkmıyor | Önce giriş yap. Sayfayı Ctrl+F5 ile yenile. |
| Bot "Bağlanamadı" diyor | Kodun süresi (15 dk) dolmuş ya da bir kez kullanılmış. Siteden bağlantıya tekrar tıkla. Bot `bot.py` eski sürümse güncelle. |
| Telegram token `Unauthorized` | Token yanlış kopyalanmış ya da BotFather'da yenilenmiş. `0` (sıfır) ile `O` (harf) karışabilir, kopyala-yapıştır yap. |
| Skor girilmiyor | `~/tahmin-ligi/log.txt`'ye bak. Gerekirse Yönetim sekmesinden elle gir. |
| Yeni maç gelmiyor | `fixtures.log`'a bak. ESPN'in veri biçimi değişmiş olabilir. |
| Supabase yanıt vermiyor | Ücretsiz projeler 1 hafta kullanılmazsa duraklatılır, panelden tek tıkla açılır. |

## Bilinen sınırlar

- Şifre sıfırlama yöneticiye bağlıdır (e-posta ile kendiliğinden sıfırlama yok).
- Skor ve fikstür verisi ESPN'in herkese açık verisinden gelir, hatalı ya da gecikmeli olabilir. Skorlar tek kaynaktan alınır.
- Betiklerin çalışması için Raspberry Pi'nin açık ve internete bağlı olması gerekir.
