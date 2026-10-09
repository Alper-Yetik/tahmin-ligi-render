-- Sohbet: oyuncular adlarıyla mesaj yazar, site 4 saniyede bir okur.
-- schema.sql'den sonra çalıştır.

create table if not exists chat_messages (
  id bigint generated always as identity primary key,
  player_id uuid not null references players(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_created on chat_messages (created_at desc);
alter table chat_messages enable row level security;
revoke all on chat_messages from anon, authenticated;

-- Herkes okuyabilir, ad ile birlikte.
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at
  from chat_messages m join players p on p.id = m.player_id;
grant select on chat_public to anon, authenticated;

-- Mesaj gönderir. Aynı oyuncu 2 saniyede birden fazla, tüm sohbet dakikada 40'tan fazla yazamaz.
-- Son 500 mesajı tutar, eskileri siler.
create or replace function send_chat(p_nick text, p_body text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  pid uuid;
  b text := btrim(coalesce(p_body, ''));
begin
  select id into pid from players where lower(nick) = lower(btrim(coalesce(p_nick, '')));
  if pid is null then return jsonb_build_object('ok', false, 'error', 'unknown_player'); end if;
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

-- Yönetici bir mesajı siler.
create or replace function admin_delete_chat(p_admin text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_ok(p_admin) then return jsonb_build_object('ok', false, 'error', 'wrong_admin'); end if;
  delete from chat_messages where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function send_chat(text, text) to anon, authenticated;
grant execute on function admin_delete_chat(text, bigint) to anon, authenticated;
