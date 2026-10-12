-- Telegram bağlantısını oturum anahtarına bağlar: üye siteden 15 dakikalık tek kullanımlık kod alır,
-- bot o kodu veritabanına gönderince sadece o üyeyle eşleşir. Oyuncu kimliği artık yetmez.
-- members.sql ve telegram.sql'den sonra çalıştır.

create table if not exists tg_link_codes (
  code_hash text primary key,
  player_id uuid not null references players(id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists tg_link_codes_player on tg_link_codes (player_id);
alter table tg_link_codes enable row level security;
revoke all on tg_link_codes from anon, authenticated;

-- Giriş yapmış üye için 15 dakikalık tek kullanımlık kod üretir (önceki kodları iptal eder).
create or replace function member_tg_code(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); c text;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  c := encode(gen_random_bytes(12), 'hex');
  delete from tg_link_codes where player_id = pid or expires_at < now();
  insert into tg_link_codes (code_hash, player_id, expires_at)
  values (encode(digest(c, 'sha256'), 'hex'), pid, now() + interval '15 minutes');
  return jsonb_build_object('ok', true, 'code', c);
end $$;

-- Otomasyon (bot): kodla Telegram sohbetini üyeye bağlar. Kod tek kullanımlıktır.
create or replace function bot_link_telegram(p_secret text, p_code text, p_chat bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; nm text;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  select player_id into pid from tg_link_codes
   where code_hash = encode(digest(coalesce(p_code, ''), 'sha256'), 'hex') and expires_at > now();
  if pid is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  delete from tg_link_codes where player_id = pid;
  select nick into nm from players where id = pid;
  insert into telegram_links (player_id, chat_id) values (pid, p_chat)
  on conflict (player_id) do update set chat_id = excluded.chat_id;
  return jsonb_build_object('ok', true, 'nick', nm);
end $$;

grant execute on function member_tg_code(text) to anon, authenticated;
grant execute on function bot_link_telegram(text, text, bigint) to anon, authenticated;

-- Eski, oyuncu kimliğiyle bağlayan sürümü (bot_link_telegram(text, uuid, bigint)) silmek için,
-- botu (bot.py) yeni sürüme güncelledikten SONRA şunu çalıştır:
--   drop function if exists bot_link_telegram(text, uuid, bigint);
