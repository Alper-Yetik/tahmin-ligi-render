# Üçlü Tahmin Ligi

Arkadaşlar arasında Fenerbahçe, Galatasaray ve Beşiktaş maçlarının (lig ve Avrupa) skor tahmini oyunu. Herkes adını yazıp tahmin girer, sonuçlar girilince puanlanır ve sıralama güncellenir.

Canlı site: https://tahmin-ligi-render.onrender.com/

## Nasıl çalışır

- **Giriş yok, hesap yok.** Oyuncu sadece adını yazar. Aynı ad her cihazdan aynı oyuncudur. Şifre ya da PIN yoktur, yani biri başkasının adını yazarak onun adına, henüz tahmin girmediği maçlara tahmin girebilir. Girilmiş tahmin kimse tarafından değiştirilemez.
- **Her maça tek tahmin.** Kaydedilince kilitlenir, değiştirilemez, silinemez (yönetici hariç).
- **Maçtan 5 saat önce kapanır.** Örneğin 20:00'de başlayan maça 15:00'e kadar tahmin girilir. Kural veritabanında uygulanır, tarayıcıdan atlatılamaz.
- **Herkesin tahmini maç kartında görünür.**
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
                                                                  └─ update_scores.py (skorlar, 2 dk'da bir)
```

| Parça | Ne yapar | Nerede |
|---|---|---|
| `index.html`, `config.js` | Site (tek sayfa, derleme yok) | Render (GitHub'dan otomatik yayın) |
| `schema.sql`, `seed.sql`, `bot.sql`, `telegram.sql` | Veritabanı tabloları, kurallar, fonksiyonlar, ilk maçlar | Supabase |
| `telegram-bot/bot.py` | Telegram: oyuncuyu bağlar, tahmin girmeyenlere hatırlatma atar | Raspberry Pi (systemd servisi) |
| `telegram-bot/sync_fixtures.py` | ESPN'den yeni maçları ekler | Raspberry Pi (cron) |
| `telegram-bot/live_scores.py` | Sürmekte olan maçların canlı skorunu yazar (canlı puan durumu) | Raspberry Pi (cron, dakikada bir) |
| `update_scores.py` | ESPN'den biten maçların skorunu yazar | Raspberry Pi (cron), bu depoda yok |

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
2. SQL Editor'de sırayla çalıştır: `schema.sql`, `seed.sql`, `bot.sql`, `telegram.sql`, `live.sql`, `chat.sql`.
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

Giriş sadece ad olduğu için biri başkasının adıyla yazabilir. Tablo (`chat_messages`) tarayıcıdan doğrudan yazılamaz, sadece `send_chat` fonksiyonuyla yazılır. Kurulum: `chat.sql`.

## Canlı puan durumu

- Raspberry'deki `live_scores.py` her dakika çalışır. Başlamış ve henüz kesin skoru girilmemiş maçlar varsa ESPN'den anlık skoru ve dakikayı çeker, Supabase'e yazar (`live_home`, `live_away`, `live_minute`, `live_state`). Böyle bir maç yoksa hiçbir ağ isteği yapmadan çıkar.
- Site canlı maçı "Canlı maçlar" bölümünde kırmızı skor ve dakika ile gösterir, tahminlerin yanında **şimdilik** kazanılan puanı yazar ve **Sıralama** sekmesini şimdiki skora göre hesaplar. Canlı maç varken sayfa 15 saniyede bir yenilenir.
- Canlı puanlar geçicidir. Maç bitince `update_scores.py` kesin skoru yazar ve puanlar kesinleşir. Canlı veri 10 dakikadır güncellenmediyse (Raspberry kapalı vb.) site onu canlı saymaz.

```bash
cd ~/tahmin-bot && python3 live_scores.py --dry-run     # ne yazacağını gösterir
(crontab -l 2>/dev/null; echo "* * * * * /usr/bin/flock -n /tmp/tahmin-live.lock /usr/bin/python3 /home/alper/tahmin-bot/live_scores.py") | crontab -
tail -20 ~/tahmin-bot/live.log
```

## Telegram hatırlatması

1. Oyuncu siteye adını yazar, üstteki **"Telegram'dan hatırlat"** bağlantısına tıklar ve botta **Başlat**'a basar. Bot oyuncuyu sohbetiyle eşler.
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
sudo systemctl restart tahmin-bot       # bot kodunu güncelledikten sonra
crontab -l                              # zamanlanmış işler
```

## Sorun giderme

| Belirti | Olası neden |
|---|---|
| Bot cevap vermiyor | `systemctl is-active tahmin-bot` ve `bot.log`'a bak. Eski cron satırı varsa kaldır (iki süreç aynı anda mesaj okuyamaz). |
| "Telegram'dan hatırlat" bağlantısı çıkmıyor | Önce adını yaz. Sayfayı Ctrl+F5 ile yenile. |
| Telegram token `Unauthorized` | Token yanlış kopyalanmış ya da BotFather'da yenilenmiş. `0` (sıfır) ile `O` (harf) karışabilir, kopyala-yapıştır yap. |
| Skor girilmiyor | `~/tahmin-ligi/log.txt`'ye bak. Gerekirse Yönetim sekmesinden elle gir. |
| Yeni maç gelmiyor | `fixtures.log`'a bak. ESPN'in veri biçimi değişmiş olabilir. |
| Supabase yanıt vermiyor | Ücretsiz projeler 1 hafta kullanılmazsa duraklatılır, panelden tek tıkla açılır. |

## Bilinen sınırlar

- Ad ile giriş: başkası senin adını yazarsa senin adına, tahmin girmediğin maçlara tahmin girebilir.
- Skor ve fikstür verisi ESPN'in herkese açık verisinden gelir, hatalı ya da gecikmeli olabilir. Skorlar tek kaynaktan alınır.
- Betiklerin çalışması için Raspberry Pi'nin açık ve internete bağlı olması gerekir.
