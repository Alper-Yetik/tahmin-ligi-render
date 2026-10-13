-- Tahminlere emoji tepkisi ve tahmini sohbette alıntılayıp yorum yazma.
-- schema.sql, members.sql, chat.sql, chat_reply.sql ve chat_edit.sql'den sonra çalıştır. Tekrar çalıştırılabilir.

-- ---------- 1) Tahmin tepkileri ----------
-- Bir üye, bir tahmine (maç + tahmini veren üye) en fazla bir tepki bırakır.
-- Aynı tepkiye tekrar basınca geri alır, farklı tepkiye basınca değiştirir. Tepki bir emojidir (chat_reactions_any.sql ile aynı kural).
create table if not exists prediction_reactions (
  match_id text not null,
  target_id uuid not null,
  reactor_id uuid not null references players(id) on delete cascade,
  kind text not null check (char_length(kind) between 1 and 16 and kind !~ '[[:alnum:][:space:]<>&"'']'),
  created_at timestamptz not null default now(),
  primary key (match_id, target_id, reactor_id),
  foreign key (match_id, target_id) references predictions(match_id, player_id) on delete cascade
);
alter table prediction_reactions enable row level security;
revoke all on prediction_reactions from anon, authenticated;

create or replace view prediction_reactions_public as
  select r.match_id, r.target_id, r.reactor_id, p.nick, r.kind
  from prediction_reactions r join players p on p.id = r.reactor_id;
grant select on prediction_reactions_public to anon, authenticated;

create or replace function react_prediction(p_token text, p_match text, p_target uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); cur text; k text := p_kind;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if k is null or char_length(k) not between 1 and 16 or k ~ '[[:alnum:][:space:]<>&"'']' then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  if not exists (select 1 from predictions where match_id = p_match and player_id = p_target) then
    return jsonb_build_object('ok', false, 'error', 'no_prediction');
  end if;
  if (select count(*) from prediction_reactions where reactor_id = pid and created_at > now() - interval '1 minute') >= 30 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  select kind into cur from prediction_reactions where match_id = p_match and target_id = p_target and reactor_id = pid;
  if cur = k then
    delete from prediction_reactions where match_id = p_match and target_id = p_target and reactor_id = pid;
    return jsonb_build_object('ok', true, 'removed', true);
  end if;
  insert into prediction_reactions (match_id, target_id, reactor_id, kind) values (p_match, p_target, pid, k)
  on conflict (match_id, target_id, reactor_id) do update set kind = excluded.kind, created_at = now();
  return jsonb_build_object('ok', true, 'removed', false);
end $$;
grant execute on function react_prediction(text, text, uuid, text) to anon, authenticated;

-- ---------- 2) Sohbette tahmin alıntısı ----------
-- Mesaj bir tahmini (maç + tahmini veren üye) alıntılayabilir. Maç ya da üye silinirse alıntı boşalır.
alter table chat_messages add column if not exists pred_match text references matches(id) on delete set null;
alter table chat_messages add column if not exists pred_player uuid references players(id) on delete set null;

-- Yeni sütunlar sona eklenir (create or replace view için eski sıra korunmalı).
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image,
         m.reply_to, rp.nick as reply_nick, r.body as reply_body, r.image as reply_image,
         (m.deleted_at is not null) as deleted, m.edited_at, (r.deleted_at is not null) as reply_deleted,
         m.pred_match, m.pred_player, pp.nick as pred_nick, pr.h as pred_h, pr.a as pred_a,
         mt.home as pred_home, mt.away as pred_away, mt.home_score as pred_hs, mt.away_score as pred_as
  from chat_messages m
  join players p on p.id = m.player_id
  left join chat_messages r on r.id = m.reply_to
  left join players rp on rp.id = r.player_id
  left join players pp on pp.id = m.pred_player
  left join predictions pr on pr.match_id = m.pred_match and pr.player_id = m.pred_player
  left join matches mt on mt.id = m.pred_match;
grant select on chat_public to anon, authenticated;

-- send_chat'e iki isteğe bağlı parametre eklenir. Eski imzayı sil, yoksa çağrı belirsiz olur.
drop function if exists send_chat(text, text, bigint);

create or replace function send_chat(p_token text, p_body text, p_reply bigint default null,
                                     p_pred_match text default null, p_pred_player uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); b text := btrim(coalesce(p_body, ''));
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if char_length(b) < 1 or char_length(b) > 300 then return jsonb_build_object('ok', false, 'error', 'invalid_body'); end if;
  if p_reply is not null and not exists (select 1 from chat_messages where id = p_reply) then
    return jsonb_build_object('ok', false, 'error', 'no_message');
  end if;
  if (p_pred_match is null) <> (p_pred_player is null) then
    return jsonb_build_object('ok', false, 'error', 'no_prediction');
  end if;
  if p_pred_match is not null and not exists (select 1 from predictions where match_id = p_pred_match and player_id = p_pred_player) then
    return jsonb_build_object('ok', false, 'error', 'no_prediction');
  end if;
  if exists (select 1 from chat_messages where player_id = pid and created_at > now() - interval '2 seconds') then
    return jsonb_build_object('ok', false, 'error', 'too_fast');
  end if;
  if (select count(*) from chat_messages where created_at > now() - interval '1 minute') >= 40 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into chat_messages (player_id, body, reply_to, pred_match, pred_player)
  values (pid, b, p_reply, p_pred_match, p_pred_player);
  delete from chat_messages where id <= coalesce((select id from chat_messages order by id desc offset 500 limit 1), 0);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function send_chat(text, text, bigint, text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
