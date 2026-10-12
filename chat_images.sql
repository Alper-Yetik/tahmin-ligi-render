-- Sohbete görsel ekleme. chat.sql ve members.sql'den sonra çalıştır.
-- Görseller tarayıcıda küçültülüp (en çok 1280 px, ~500 KB) Supabase Storage'daki herkese açık
-- "chat-images" klasörüne rastgele bir adla yüklenir. Mesaja sadece bu ad yazılır.

alter table chat_messages add column if not exists image text;
alter table chat_messages drop constraint if exists chat_messages_image_check;
alter table chat_messages add constraint chat_messages_image_check
  check (image is null or image ~ '^[0-9a-f]{32}\.jpg$');
alter table chat_messages drop constraint if exists chat_messages_body_check;
alter table chat_messages add constraint chat_messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image is not null));

-- Sütunu sona ekleyerek görünümü günceller.
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image
  from chat_messages m join players p on p.id = m.player_id;
grant select on chat_public to anon, authenticated;

-- Klasör: herkes görebilir, yükleme sadece jpeg ve en çok 600 KB. Dosya mesaja bağlanmadıkça sohbette görünmez.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', true, 614400, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "chat images upload" on storage.objects;
create policy "chat images upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'chat-images');

-- Giriş yapmış oyuncu görselli mesaj gönderir. Aynı sınırlar: 2 saniyede bir, dakikada en çok 10 görsel.
create or replace function send_chat_image(p_token text, p_body text, p_image text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_image is null or p_image !~ '^[0-9a-f]{32}\.jpg$'
     or not exists (select 1 from storage.objects where bucket_id = 'chat-images' and name = p_image) then
    return jsonb_build_object('ok', false, 'error', 'invalid_image');
  end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where image is not null and created_at > now() - interval '1 minute') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body, image) values (pid, b, p_image);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function send_chat_image(text, text, text) to anon, authenticated;
