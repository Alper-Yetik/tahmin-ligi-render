-- Sohbet tepkileri (WhatsApp gibi): bir üye bir mesaja en fazla bir tepki bırakır.
-- Aynı tepkiye tekrar basınca geri alır, farklı tepkiye basınca değiştirir.
-- chat.sql ve members.sql'den sonra çalıştır.
-- Tepki "kodu" saklanır, emoji siteye aittir: like=👍 love=❤️ laugh=😂 wow=😮 sad=😢 fire=🔥 ball=⚽

create table if not exists chat_reactions (
  message_id bigint not null references chat_messages(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  kind text not null check (kind in ('like', 'love', 'laugh', 'wow', 'sad', 'fire', 'ball')),
  created_at timestamptz not null default now(),
  primary key (message_id, player_id)
);
create index if not exists chat_reactions_msg on chat_reactions (message_id);
alter table chat_reactions enable row level security;
revoke all on chat_reactions from anon, authenticated;

-- Herkes okuyabilir (kim hangi tepkiyi bıraktı, ad ile).
create or replace view chat_reactions_public as
  select r.message_id, r.player_id, p.nick, r.kind
  from chat_reactions r join players p on p.id = r.player_id;
grant select on chat_reactions_public to anon, authenticated;

-- Tepki bırakır, değiştirir ya da geri alır. Üye başına dakikada en fazla 30 işlem.
create or replace function react_chat(p_token text, p_message bigint, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); cur text;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_kind is null or p_kind not in ('like', 'love', 'laugh', 'wow', 'sad', 'fire', 'ball') then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if not exists (select 1 from chat_messages where id = p_message) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if (select count(*) from chat_reactions where player_id = pid and created_at > now() - interval '1 minute') >= 30 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  select kind into cur from chat_reactions where message_id = p_message and player_id = pid;
  if cur = p_kind then
    delete from chat_reactions where message_id = p_message and player_id = pid;
    return jsonb_build_object('ok', true, 'removed', true);
  end if;
  insert into chat_reactions (message_id, player_id, kind) values (p_message, pid, p_kind)
  on conflict (message_id, player_id) do update set kind = excluded.kind, created_at = now();
  return jsonb_build_object('ok', true, 'removed', false);
end $$;

grant execute on function react_chat(text, bigint, text) to anon, authenticated;
