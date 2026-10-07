# Üçlü Tahmin Ligi (Render + Supabase)

Dosyalar:
- `index.html`: site (tek dosya, derleme gerekmez)
- `config.js`: Supabase adresi ve anon anahtarı
- `schema.sql`: veritabanı tabloları ve kuralları
- `seed.sql`: mevcut 35 maç

## 1. Supabase (veritabanı)
1. supabase.com'da ücretsiz hesap aç, **New project** ile proje oluştur (bölge: Frankfurt uygundur).
2. Sol menüde **SQL Editor** > yeni sorgu aç.
3. `schema.sql` içeriğini yapıştırıp **Run** de.
4. Yeni sorguda `seed.sql` içeriğini yapıştırıp **Run** de.
5. Yönetici şifreni kaydet. Yeni sorguda şunu çalıştır (`BURAYA_SIFRE` yerine kendi güçlü şifreni yaz):

```sql
insert into admin_config (key, value)
values ('admin_hash', crypt('BURAYA_SIFRE', gen_salt('bf')))
on conflict (key) do update set value = excluded.value;
```

6. **Project Settings > API** sayfasından iki bilgiyi al:
   - Project URL (`https://xxxx.supabase.co`)
   - `anon` / `publishable` anahtar (**service_role değil**)
7. Bu iki bilgiyi `config.js` içine yaz.

## 2. Render (site)
Render ücretsiz **Static Site** için kodu bir GitHub deposundan çeker.
1. GitHub'da yeni bir depo aç, bu klasördeki dosyaları yükle.
2. render.com > **New > Static Site** > depoyu seç.
3. Build Command: boş bırak. Publish Directory: `.`
4. **Create Static Site**. Birkaç dakika sonra `https://....onrender.com` adresin hazır olur.

## Notlar
- Ücretsiz Supabase projeleri 1 hafta hiç kullanılmazsa duraklatılır; panelden tek tıkla açılır.
- Oyuncular sadece adını yazar, PIN yoktur. Her maça tek tahmin; kilitleme ve maç başlangıç kontrolü sunucuda yapılır.
