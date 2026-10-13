-- Sohbette hareketli GIF gönderme (galeriden ya da klavyeden yapıştırarak).
-- chat_images.sql ve chat_reply.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- GIF'ler küçültülmeden olduğu gibi yüklenir (animasyon bozulmasın diye). En çok 3 MB.

-- Klasör hem jpeg hem gif kabul eder, dosya sınırı 3 MB olur.
update storage.buckets
   set file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/gif']
 where id = 'chat-images';

-- Mesajdaki görsel adı rastgele 32 karakter + .jpg ya da .gif olabilir.
alter table chat_messages drop constraint if exists chat_messages_image_check;
alter table chat_messages add constraint chat_messages_image_check
  check (image is null or image ~ '^[0-9a-f]{32}\.(jpg|gif)$');

create or replace function send_chat_image(p_token text, p_body text, p_image text, p_reply bigint default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_image is null or p_image !~ '^[0-9a-f]{32}\.(jpg|gif)$'
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
grant execute on function send_chat_image(text, text, text, bigint) to anon, authenticated;
