-- Üyelik: kullanıcı adı + şifre, oturum anahtarı, tek kullanımlık kodla hesap sahiplenme.
-- Diğer SQL dosyalarından SONRA çalıştır. Önceki ad-ile-giriş fonksiyonlarını (player_login,
-- submit_prediction(ad...), send_chat(ad...)) siler ve oturum anahtarı isteyen sürümleriyle değiştirir.

alter table players add column if not exists password_hash text;
alter table players add column if not exists claim_hash text;

create table if not exists sessions (
  token_hash text primary key,
  player_id uuid not null references players(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists sessions_player on sessions (player_id);
alter table sessions enable row level security;
revoke all on sessions from anon, authenticated;

-- ---------- Eski, şifresiz fonksiyonları kaldır ----------
drop function if exists player_login(text);
drop function if exists submit_prediction(text, text, int, int);
drop function if exists send_chat(text, text);

-- ---------- Yardımcılar (dışarıdan çağrılamaz) ----------
create or replace function session_player(p_token text)
returns uuid language sql security definer set search_path = public, extensions as $$
  select player_id from sessions
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and expires_at > now()
   limit 1
$$;

create or replace function new_session(p_player uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(24), 'hex');
begin
  delete from sessions where expires_at < now();
  insert into sessions (token_hash, player_id, expires_at)
  values (encode(digest(t, 'sha256'), 'hex'), p_player, now() + interval '60 days');
  return t;
end $$;

revoke execute on function session_player(text) from public, anon, authenticated;
revoke execute on function new_session(uuid) from public, anon, authenticated;

-- ---------- Üyelik fonksiyonları ----------
create or replace function member_register(p_nick text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare n text := btrim(coalesce(p_nick, '')); pid uuid;
begin
  -- Adın baş harfi otomatik büyük olur (Türkçe: i -> İ, ı -> I). Gerisi yazıldığı gibi kalır.
  if n <> '' then
    n := (case left(n, 1) when 'i' then 'İ' when 'ı' then 'I' else upper(left(n, 1)) end) || substr(n, 2);
  end if;
  if char_length(n) < 2 or char_length(n) > 24 or n ~ '[<>]' then return jsonb_build_object('ok', false, 'error', 'invalid_nick'); end if;
  if p_password is null or char_length(p_password) < 6 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'invalid_password'); end if;
  if (select count(*) from players where created_at > now() - interval '1 hour') >= 30 then return jsonb_build_object('ok', false, 'error', 'busy'); end if;
  if exists (select 1 from players where lower(nick) = lower(n)) then return jsonb_build_object('ok', false, 'error', 'name_taken'); end if;
  insert into players (nick, password_hash) values (n, crypt(p_password, gen_salt('bf', 10))) returning id into pid;
  return jsonb_build_object('ok', true, 'id', pid, 'nick', n, 'token', new_session(pid));
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'name_taken');
end $$;

create or replace function member_login(p_nick text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r players%rowtype; nf int;
begin
  select * into r from players where lower(nick) = lower(btrim(coalesce(p_nick, '')));
  if not found then perform pg_sleep(0.4); return jsonb_build_object('ok', false, 'error', 'wrong_credentials'); end if;
  if r.locked_until is not null and r.locked_until > now() then return jsonb_build_object('ok', false, 'error', 'locked'); end if;
  if r.password_hash is null then return jsonb_build_object('ok', false, 'error', 'not_claimed'); end if;
  if p_password is not null and r.password_hash = crypt(p_password, r.password_hash) then
    if r.failed > 0 or r.locked_until is not null then update players set failed = 0, locked_until = null where id = r.id; end if;
    return jsonb_build_object('ok', true, 'id', r.id, 'nick', r.nick, 'token', new_session(r.id));
  end if;
  nf := r.failed + 1;
  if nf >= 5 then update players set failed = 0, locked_until = now() + interval '15 minutes' where id = r.id;
  else update players set failed = nf where id = r.id; end if;
  perform pg_sleep(0.4);
  return jsonb_build_object('ok', false, 'error', 'wrong_credentials');
end $$;

-- Yöneticinin verdiği tek kullanımlık kodla hesabı sahiplenir ve şifre belirler.
create or replace function member_claim(p_nick text, p_code text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r players%rowtype; c text := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g')); nf int;
begin
  if p_password is null or char_length(p_password) < 6 or char_length(p_password) > 72 then return jsonb_build_object('ok', false, 'error', 'invalid_password'); end if;
  select * into r from players where lower(nick) = lower(btrim(coalesce(p_nick, '')));
  if not found then perform pg_sleep(0.4); return jsonb_build_object('ok', false, 'error', 'wrong_code'); end if;
  if r.locked_until is not null and r.locked_until > now() then return jsonb_build_object('ok', false, 'error', 'locked'); end if;
  if r.claim_hash is null then
    return jsonb_build_object('ok', false, 'error', case when r.password_hash is not null then 'already_claimed' else 'no_code' end);
  end if;
  if c <> '' and r.claim_hash = crypt(c, r.claim_hash) then
    update players set password_hash = crypt(p_password, gen_salt('bf', 10)), claim_hash = null, failed = 0, locked_until = null where id = r.id;
    delete from sessions where player_id = r.id;
    return jsonb_build_object('ok', true, 'id', r.id, 'nick', r.nick, 'token', new_session(r.id));
  end if;
  nf := r.failed + 1;
  if nf >= 5 then update players set failed = 0, locked_until = now() + interval '15 minutes' where id = r.id;
  else update players set failed = nf where id = r.id; end if;
  perform pg_sleep(0.4);
  return jsonb_build_object('ok', false, 'error', 'wrong_code');
end $$;

create or replace function member_me(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); nm text;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  select nick into nm from players where id = pid;
  return jsonb_build_object('ok', true, 'id', pid, 'nick', nm);
end $$;

create or replace function member_logout(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return jsonb_build_object('ok', true);
end $$;

create or replace function member_change_password(p_token text, p_old text, p_new text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); r players%rowtype;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_new is null or char_length(p_new) < 6 or char_length(p_new) > 72 then return jsonb_build_object('ok', false, 'error', 'invalid_password'); end if;
  select * into r from players where id = pid;
  if r.password_hash is null or p_old is null or r.password_hash <> crypt(p_old, r.password_hash) then
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'error', 'wrong_credentials');
  end if;
  update players set password_hash = crypt(p_new, gen_salt('bf', 10)) where id = pid;
  delete from sessions where player_id = pid and token_hash <> encode(digest(p_token, 'sha256'), 'hex');
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Tahmin ve sohbet: artık oturum anahtarı ister ----------
create or replace function submit_prediction(p_token text, p_match text, p_h int, p_a int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); k timestamptz; n int;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_h is null or p_a is null or p_h not between 0 and 30 or p_a not between 0 and 30 then
    return jsonb_build_object('ok', false, 'error', 'invalid_score');
  end if;
  select kickoff into k from matches where id = p_match;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_match'); end if;
  if k - interval '5 hours' <= now() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  insert into predictions (match_id, player_id, h, a) values (p_match, pid, p_h, p_a)
  on conflict (match_id, player_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'already_predicted'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function send_chat(p_token text, p_body text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) < 1 or char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where created_at > now() - interval '1 minute') >= 40 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body) values (pid, b);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Yönetici: oyuncu listesi ve kod üretme ----------
create or replace function admin_list_players(p_admin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  return jsonb_build_object('ok', true, 'players', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nick', p.nick, 'claimed', p.password_hash is not null, 'has_code', p.claim_hash is not null,
      'preds', (select count(*) from predictions x where x.player_id = p.id)) order by lower(p.nick))
    from players p), '[]'::jsonb));
end $$;

-- Oyuncunun şifresini sıfırlar ve tek kullanımlık kod üretir (kod sadece bu çağrıda görünür).
create or replace function admin_reset_player(p_admin text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c text := upper(encode(gen_random_bytes(4), 'hex'));
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  update players set claim_hash = crypt(c, gen_salt('bf')), password_hash = null, failed = 0, locked_until = null where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_player'); end if;
  delete from sessions where player_id = p_id;
  return jsonb_build_object('ok', true, 'code', substr(c, 1, 4) || '-' || substr(c, 5, 4));
end $$;

grant execute on function member_register(text, text) to anon, authenticated;
grant execute on function member_login(text, text) to anon, authenticated;
grant execute on function member_claim(text, text, text) to anon, authenticated;
grant execute on function member_me(text) to anon, authenticated;
grant execute on function member_logout(text) to anon, authenticated;
grant execute on function member_change_password(text, text, text) to anon, authenticated;
grant execute on function submit_prediction(text, text, int, int) to anon, authenticated;
grant execute on function send_chat(text, text) to anon, authenticated;
grant execute on function admin_list_players(text) to anon, authenticated;
grant execute on function admin_reset_player(text, uuid) to anon, authenticated;
