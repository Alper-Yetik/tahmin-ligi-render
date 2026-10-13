-- Sohbette GIF arama ve gönderme (Giphy).
-- chat_edit.sql ve pred_social.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- GIF dosyası yüklenmez: mesajda sadece Giphy kimliği (harf-rakam) saklanır, görsel Giphy'den gelir.

alter table chat_messages add column if not exists gif text;
alter table chat_messages drop constraint if exists chat_messages_gif_check;
alter table chat_messages add constraint chat_messages_gif_check check (gif is null or gif ~ '^[A-Za-z0-9]{5,40}$');

-- Mesajın metni boş olabilir: fotoğraf, GIF ya da silinmiş mesajda.
alter table chat_messages drop constraint if exists chat_messages_body_check;
alter table chat_messages add constraint chat_messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image is not null or gif is not null or deleted_at is not null));

-- Yeni sütunlar sona eklenir (create or replace view için eski sıra korunmalı).
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image,
         m.reply_to, rp.nick as reply_nick, r.body as reply_body, r.image as reply_image,
         (m.deleted_at is not null) as deleted, m.edited_at, (r.deleted_at is not null) as reply_deleted,
         m.pred_match, m.pred_player, pp.nick as pred_nick, pr.h as pred_h, pr.a as pred_a,
         mt.home as pred_home, mt.away as pred_away, mt.home_score as pred_hs, mt.away_score as pred_as,
         m.gif, r.gif as reply_gif
  from chat_messages m
  join players p on p.id = m.player_id
  left join chat_messages r on r.id = m.reply_to
  left join players rp on rp.id = r.player_id
  left join players pp on pp.id = m.pred_player
  left join predictions pr on pr.match_id = m.pred_match and pr.player_id = m.pred_player
  left join matches mt on mt.id = m.pred_match;
grant select on chat_public to anon, authenticated;

-- Giriş yapmış üye GIF gönderir. Aynı sınırlar: 2 saniyede bir, dakikada en çok 10 görsel/GIF.
create or replace function send_chat_gif(p_token text, p_body text, p_gif text, p_reply bigint default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_gif is null or p_gif !~ '^[A-Za-z0-9]{5,40}$' then return jsonb_build_object('ok', false, 'error', 'invalid_gif'); end if;
  if p_reply is not null and not exists (select 1 from chat_messages where id = p_reply) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where (image is not null or gif is not null) and created_at > now() - interval '1 minute') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body, gif, reply_to) values (pid, b, p_gif, p_reply);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function send_chat_gif(text, text, text, bigint) to anon, authenticated;

-- Silerken GIF bağlantısı da temizlenir.
create or replace function delete_chat(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  update chat_messages set body = '', image = null, gif = null, deleted_at = now()
   where id = p_id and player_id = pid and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  delete from chat_reactions where message_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- GIF'li mesajın yazısı (altyazı) boş bırakılabilir.
create or replace function edit_chat(p_token text, p_id bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, '')); m record;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  select * into m from chat_messages where id = p_id and player_id = pid and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if m.created_at < now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'error', 'too_late'); end if;
  if char_length(b) > 300 or (char_length(b) < 1 and m.image is null and m.gif is null) then
    return jsonb_build_object('ok', false, 'error', 'invalid_body');
  end if;
  if b <> m.body then
    update chat_messages set body = b, edited_at = now() where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

notify pgrst, 'reload schema';
