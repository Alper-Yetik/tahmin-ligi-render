-- Üçlü Tahmin Ligi: Supabase veritabanı kurulumu
-- Supabase panelinde SQL Editor'e yapıştırıp bir kez çalıştır.

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablolar ----------
create table if not exists matches (
  id text primary key,
  home text not null,
  away text not null,
  comp text not null,
  kickoff timestamptz not null,
  home_score int check (home_score >= 0),
  away_score int check (away_score >= 0),
  created_at timestamptz not null default now()
);

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  nick text not null,
  pin_hash text not null,
  failed int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists players_nick_lower on players (lower(nick));

create table if not exists predictions (
  match_id text not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  h int not null check (h between 0 and 30),
  a int not null check (a between 0 and 30),
  created_at timestamptz not null default now(),
  primary key (match_id, player_id)
);

create table if not exists admin_config (
  key text primary key,
  value text not null
);

-- ---------- Erişim kuralları ----------
alter table matches enable row level security;
alter table players enable row level security;
alter table predictions enable row level security;
alter table admin_config enable row level security;

revoke all on matches, players, predictions, admin_config from anon, authenticated;
grant select on matches, predictions to anon, authenticated;

drop policy if exists matches_read on matches;
create policy matches_read on matches for select to anon, authenticated using (true);
drop policy if exists predictions_read on predictions;
create policy predictions_read on predictions for select to anon, authenticated using (true);

-- Oyuncu listesi: sadece id ve takma ad görünür, PIN karması asla.
create or replace view players_public as select id, nick from players;
grant select on players_public to anon, authenticated;

-- ---------- Yardımcı fonksiyonlar (dışarıdan çağrılamaz) ----------
create or replace function auth_player(p_nick text, p_pin text, p_create boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  r players%rowtype;
  n text := btrim(coalesce(p_nick, ''));
  nf int;
begin
  if char_length(n) < 2 or char_length(n) > 24 then return jsonb_build_object('error', 'invalid_nick'); end if;
  if p_pin is null or char_length(p_pin) < 4 or char_length(p_pin) > 32 then return jsonb_build_object('error', 'invalid_pin'); end if;
  select * into r from players where lower(nick) = lower(n);
  if not found then
    if not p_create then return jsonb_build_object('error', 'unknown_player'); end if;
    insert into players (nick, pin_hash) values (n, crypt(p_pin, gen_salt('bf'))) returning * into r;
    return jsonb_build_object('id', r.id, 'nick', r.nick, 'created', true);
  end if;
  if r.locked_until is not null and r.locked_until > now() then return jsonb_build_object('error', 'locked'); end if;
  if r.pin_hash = crypt(p_pin, r.pin_hash) then
    if r.failed > 0 or r.locked_until is not null then
      update players set failed = 0, locked_until = null where id = r.id;
    end if;
    return jsonb_build_object('id', r.id, 'nick', r.nick, 'created', false);
  end if;
  nf := r.failed + 1;
  if nf >= 5 then
    update players set failed = 0, locked_until = now() + interval '15 minutes' where id = r.id;
  else
    update players set failed = nf where id = r.id;
  end if;
  return jsonb_build_object('error', 'wrong_pin');
end $$;

create or replace function admin_ok(p_admin text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select value into h from admin_config where key = 'admin_hash';
  if h is not null and p_admin is not null and h = crypt(p_admin, h) then return true; end if;
  perform pg_sleep(1);
  return false;
end $$;

revoke execute on function auth_player(text, text, boolean) from public, anon, authenticated;
revoke execute on function admin_ok(text) from public, anon, authenticated;

-- ---------- Oyuncu fonksiyonları ----------
-- Takma ad yoksa kaydeder, varsa PIN'i doğrular.
create or replace function player_login(p_nick text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb;
begin
  a := auth_player(p_nick, p_pin, true);
  if a->>'error' is not null then return jsonb_build_object('ok', false, 'error', a->>'error'); end if;
  return jsonb_build_object('ok', true, 'id', a->>'id', 'nick', a->>'nick', 'created', (a->>'created')::boolean);
end $$;

-- Maç başlamadan bir kez tahmin girilir. Değiştirilemez.
create or replace function submit_prediction(p_nick text, p_pin text, p_match text, p_h int, p_a int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  a jsonb;
  k timestamptz;
  n int;
begin
  a := auth_player(p_nick, p_pin, false);
  if a->>'error' is not null then return jsonb_build_object('ok', false, 'error', a->>'error'); end if;
  if p_h is null or p_a is null or p_h not between 0 and 30 or p_a not between 0 and 30 then
    return jsonb_build_object('ok', false, 'error', 'invalid_score');
  end if;
  select kickoff into k from matches where id = p_match;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_match'); end if;
  if k <= now() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  insert into predictions (match_id, player_id, h, a)
  values (p_match, (a->>'id')::uuid, p_h, p_a)
  on conflict (match_id, player_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'already_predicted'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Yönetici fonksiyonları ----------
create or replace function admin_check(p_admin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Maç ekler; aynı id varsa isim, organizasyon ve saati günceller (skora dokunmaz).
create or replace function admin_upsert_match(p_admin text, p_id text, p_home text, p_away text, p_comp text, p_kickoff timestamptz)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  insert into matches (id, home, away, comp, kickoff) values (p_id, p_home, p_away, p_comp, p_kickoff)
  on conflict (id) do update set home = excluded.home, away = excluded.away, comp = excluded.comp, kickoff = excluded.kickoff;
  return jsonb_build_object('ok', true);
end $$;

-- Sonuç yazar. Skorlar null gönderilirse sonuç silinir.
create or replace function admin_set_result(p_admin text, p_id text, p_hs int, p_as int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  update matches set home_score = p_hs, away_score = p_as where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function admin_delete_match(p_admin text, p_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  delete from matches where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function player_login(text, text) to anon, authenticated;
grant execute on function submit_prediction(text, text, text, int, int) to anon, authenticated;
grant execute on function admin_check(text) to anon, authenticated;
grant execute on function admin_upsert_match(text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function admin_set_result(text, text, int, int) to anon, authenticated;
grant execute on function admin_delete_match(text, text) to anon, authenticated;
