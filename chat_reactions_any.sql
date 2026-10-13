-- Sohbet tepkilerinde herhangi bir emoji (WhatsApp'taki "+" gibi).
-- chat_reactions.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Artık "kind" sütununda emojinin kendisi saklanır; eski kodlar (like, love...) emojiye çevrilir.

alter table chat_reactions drop constraint if exists chat_reactions_kind_check;

update chat_reactions set kind = case kind
  when 'like' then '👍' when 'love' then '❤️' when 'laugh' then '😂'
  when 'wow' then '😮' when 'sad' then '😢' when 'fire' then '🔥' when 'ball' then '⚽'
  else kind end
where kind in ('like', 'love', 'laugh', 'wow', 'sad', 'fire', 'ball');

-- Emoji doğrulaması: 1-16 karakter; harf, rakam, boşluk ve HTML işaretleri olamaz.
alter table chat_reactions add constraint chat_reactions_kind_check
  check (char_length(kind) between 1 and 16 and kind !~ '[[:alnum:][:space:]<>&"'']');

create or replace function react_chat(p_token text, p_message bigint, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); cur text; k text := p_kind;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  -- eski site sürümleri kod gönderebilir
  k := case k when 'like' then '👍' when 'love' then '❤️' when 'laugh' then '😂'
              when 'wow' then '😮' when 'sad' then '😢' when 'fire' then '🔥' when 'ball' then '⚽' else k end;
  if k is null or char_length(k) not between 1 and 16 or k ~ '[[:alnum:][:space:]<>&"'']' then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if not exists (select 1 from chat_messages where id = p_message) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if (select count(*) from chat_reactions where player_id = pid and created_at > now() - interval '1 minute') >= 30 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  select kind into cur from chat_reactions where message_id = p_message and player_id = pid;
  if cur = k then
    delete from chat_reactions where message_id = p_message and player_id = pid;
    return jsonb_build_object('ok', true, 'removed', true);
  end if;
  insert into chat_reactions (message_id, player_id, kind) values (p_message, pid, k)
  on conflict (message_id, player_id) do update set kind = excluded.kind, created_at = now();
  return jsonb_build_object('ok', true, 'removed', false);
end $$;

grant execute on function react_chat(text, bigint, text) to anon, authenticated;
