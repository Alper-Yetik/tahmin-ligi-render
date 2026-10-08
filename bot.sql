-- Otomasyon fonksiyonları: sınırlı yetkili anahtarla maç ekler ve skor yazar.
-- schema.sql'den sonra çalıştır. telegram.sql bu dosyadaki bot_ok fonksiyonunu kullanır.

-- Otomasyon anahtarını belirle (BURAYA_OTOMASYON_ANAHTARI yerine uzun, rastgele bir metin yaz):
--   insert into admin_config (key, value)
--   values ('bot_hash', crypt('BURAYA_OTOMASYON_ANAHTARI', gen_salt('bf')))
--   on conflict (key) do update set value = excluded.value;

create or replace function bot_ok(p_secret text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from admin_config where key = 'bot_hash';
  if h is not null and p_secret is not null and h = crypt(p_secret, h) then return true; end if;
  perform pg_sleep(1);
  return false;
end $$;
revoke execute on function bot_ok(text) from public, anon, authenticated;

-- Maç ekler ya da günceller (skora dokunmaz).
create or replace function bot_upsert_match(p_secret text, p_id text, p_home text, p_away text, p_comp text, p_kickoff timestamptz)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  insert into matches (id, home, away, comp, kickoff) values (p_id, p_home, p_away, p_comp, p_kickoff)
  on conflict (id) do update set home = excluded.home, away = excluded.away, comp = excluded.comp, kickoff = excluded.kickoff;
  return jsonb_build_object('ok', true);
end $$;

-- Sadece henüz skoru girilmemiş ve başlamış maça skor yazar. Girilmiş skoru değiştirmez.
create or replace function bot_set_result(p_secret text, p_id text, p_hs int, p_as int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c int;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_hs is null or p_as is null or p_hs < 0 or p_as < 0 then return jsonb_build_object('ok', false, 'error', 'invalid_score'); end if;
  update matches set home_score = p_hs, away_score = p_as
  where id = p_id and home_score is null and away_score is null and kickoff < now();
  get diagnostics c = row_count;
  if c = 0 then return jsonb_build_object('ok', false, 'error', 'not_updated'); end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_upsert_match(text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function bot_set_result(text, text, int, int) to anon, authenticated;
