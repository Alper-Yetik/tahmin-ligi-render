-- Sohbette mesaj silme ve düzenleme (WhatsApp gibi).
-- chat.sql, members.sql, chat_images.sql ve chat_reply.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Silinen mesaj tablodan kalkmaz, "Bu mesaj silindi" olarak kalır (içerik ve fotoğraf bağlantısı temizlenir).
-- Düzenleme gönderdikten sonra 15 dakika içinde yapılabilir.

alter table chat_messages add column if not exists deleted_at timestamptz;
alter table chat_messages add column if not exists edited_at timestamptz;

-- Silinen mesajın metni boş olabilir.
alter table chat_messages drop constraint if exists chat_messages_body_check;
alter table chat_messages add constraint chat_messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image is not null or deleted_at is not null));

-- Yeni sütunlar sona eklenir (create or replace view için eski sıra korunmalı).
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image,
         m.reply_to, rp.nick as reply_nick, r.body as reply_body, r.image as reply_image,
         (m.deleted_at is not null) as deleted, m.edited_at, (r.deleted_at is not null) as reply_deleted
  from chat_messages m
  join players p on p.id = m.player_id
  left join chat_messages r on r.id = m.reply_to
  left join players rp on rp.id = r.player_id;
grant select on chat_public to anon, authenticated;

-- Üye kendi mesajını herkesten siler.
create or replace function delete_chat(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  update chat_messages set body = '', image = null, deleted_at = now()
   where id = p_id and player_id = pid and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  delete from chat_reactions where message_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Üye kendi mesajının metnini gönderdikten sonra 15 dakika içinde değiştirir.
create or replace function edit_chat(p_token text, p_id bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, '')); m record;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  select * into m from chat_messages where id = p_id and player_id = pid and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if m.created_at < now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'error', 'too_late'); end if;
  if char_length(b) > 300 or (char_length(b) < 1 and m.image is null) then
    return jsonb_build_object('ok', false, 'error', 'invalid_body');
  end if;
  if b <> m.body then
    update chat_messages set body = b, edited_at = now() where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function delete_chat(text, bigint) to anon, authenticated;
grant execute on function edit_chat(text, bigint, text) to anon, authenticated;

notify pgrst, 'reload schema';
