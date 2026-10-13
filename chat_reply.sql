-- Sohbette mesaja yanıt verme (WhatsApp gibi alıntılı yanıt).
-- chat.sql, members.sql ve chat_images.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Yanıtlanan mesaj silinirse yanıtın alıntısı kaybolur, yanıt mesajı kalır.

alter table chat_messages add column if not exists reply_to bigint references chat_messages(id) on delete set null;

-- Sütunlar sona eklenir (create or replace view için eski sıra korunmalı).
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image,
         m.reply_to, rp.nick as reply_nick, r.body as reply_body, r.image as reply_image
  from chat_messages m
  join players p on p.id = m.player_id
  left join chat_messages r on r.id = m.reply_to
  left join players rp on rp.id = r.player_id;
grant select on chat_public to anon, authenticated;

-- Eski imzaları sil, yoksa aynı adlı iki fonksiyon çağrıyı belirsiz yapar.
drop function if exists send_chat(text, text);
drop function if exists send_chat_image(text, text, text);

create or replace function send_chat(p_token text, p_body text, p_reply bigint default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) < 1 or char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_reply is not null and not exists (select 1 from chat_messages where id = p_reply) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where created_at > now() - interval '1 minute') >= 40 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body, reply_to) values (pid, b, p_reply);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;

create or replace function send_chat_image(p_token text, p_body text, p_image text, p_reply bigint default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_image is null or p_image !~ '^[0-9a-f]{32}\.jpg$'
     or not exists (select 1 from storage.objects where bucket_id = 'chat-images' and name = p_image) then
    return jsonb_build_object('ok', false, 'error', 'invalid_image');
  end if;
  if p_reply is not null and not exists (select 1 from chat_messages where id = p_reply) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where image is not null and created_at > now() - interval '1 minute') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body, image, reply_to) values (pid, b, p_image, p_reply);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;

grant execute on function send_chat(text, text, bigint) to anon, authenticated;
grant execute on function send_chat_image(text, text, text, bigint) to anon, authenticated;
