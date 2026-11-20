-- Sohbet bildirimleri (Web Push). chat.sql, chat_images.sql ve chat_gif.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Akış: telefon aboneliği push_subscribe ile kaydedilir. Yeni sohbet mesajında tetikleyici, Supabase Edge Function
-- "chat-push"u (supabase/functions/chat-push/index.ts) gövdesiz çağırır. Fonksiyon gelen isteğe güvenmez:
-- gönderilmemiş mesajları push_claim() ile kendisi alır, bu yüzden dışarıdan çağrılması zararsızdır.
-- Fonksiyonun VAPID_PUBLIC_KEY ve VAPID_PRIVATE_KEY gizlileri Supabase > Edge Functions > Secrets'ta durur.

create table if not exists push_subs (
  endpoint text primary key check (char_length(endpoint) between 10 and 1000 and endpoint ~ '^https://'),
  player_id uuid not null references players(id) on delete cascade,
  p256dh text not null check (char_length(p256dh) between 20 and 200),
  auth text not null check (char_length(auth) between 8 and 100),
  created_at timestamptz not null default now()
);
create index if not exists push_subs_player on push_subs (player_id);
alter table push_subs enable row level security;
revoke all on push_subs from anon, authenticated;

create or replace function push_subscribe(p_token text, p_endpoint text, p_p256dh text, p_auth text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) not between 10 and 1000
     or char_length(coalesce(p_p256dh, '')) not between 20 and 200 or char_length(coalesce(p_auth, '')) not between 8 and 100 then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  insert into push_subs (endpoint, player_id, p256dh, auth) values (p_endpoint, pid, p_p256dh, p_auth)
  on conflict (endpoint) do update set player_id = excluded.player_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  -- oyuncu başına en fazla 10 cihaz: eskileri sil
  delete from push_subs where player_id = pid and endpoint in (
    select endpoint from push_subs where player_id = pid order by created_at desc offset 10);
  return jsonb_build_object('ok', true);
end $$;

create or replace function push_unsubscribe(p_token text, p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  delete from push_subs where endpoint = p_endpoint and player_id = pid;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function push_subscribe(text, text, text, text) to anon, authenticated;
grant execute on function push_unsubscribe(text, text) to anon, authenticated;

-- Hangi mesaja kadar bildirim gönderildi (tek satır).
create table if not exists push_state (
  id int primary key default 1 check (id = 1),
  last_id bigint not null default 0
);
alter table push_state enable row level security;
revoke all on push_state from anon, authenticated;
insert into push_state (id, last_id) values (1, (select coalesce(max(id), 0) from chat_messages))
on conflict (id) do nothing;

-- Henüz bildirimi gönderilmemiş mesajları döndürür ve işaretler (aynı mesaj iki kez gönderilmez).
create or replace function push_claim()
returns table (id bigint, player_id uuid, nick text, body text, image text, gif text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare old_id bigint; new_id bigint;
begin
  select s.last_id into old_id from push_state s where s.id = 1 for update;
  select coalesce(max(m.id), old_id) into new_id from chat_messages m;
  if new_id <= old_id then return; end if;
  update push_state set last_id = new_id where push_state.id = 1;
  return query
    select m.id, m.player_id, p.nick, m.body, m.image, m.gif
    from chat_messages m join players p on p.id = m.player_id
    where m.id > old_id and m.id <= new_id and m.deleted_at is null
    order by m.id desc limit 10;
end $$;
revoke execute on function push_claim() from public, anon, authenticated;
grant execute on function push_claim() to service_role;

-- Yeni mesajda Edge Function'ı çağır (pg_net, arka planda). Hata olsa bile mesaj gönderimi etkilenmez.
create extension if not exists pg_net;

create or replace function chat_push_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform net.http_post(
      url := 'https://ecumfsoqquswjhphqciz.supabase.co/functions/v1/chat-push',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists chat_push on chat_messages;
create trigger chat_push after insert on chat_messages
  for each statement execute function chat_push_notify();
