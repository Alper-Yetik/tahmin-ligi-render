-- Telegram hatırlatmaları: oyuncu bota /start deyince sohbet kimliği oyuncuyla eşlenir.
create table if not exists telegram_links (
  player_id uuid primary key references players(id) on delete cascade,
  chat_id bigint not null,
  created_at timestamptz not null default now()
);
create table if not exists telegram_reminders (
  match_id text not null references matches(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (match_id, player_id)
);
alter table telegram_links enable row level security;
alter table telegram_reminders enable row level security;
revoke all on telegram_links, telegram_reminders from anon, authenticated;

-- Sitede "Telegram bağlı" göstermek için sadece oyuncu kimliği görünür, sohbet kimliği asla.
create or replace view players_telegram as select player_id from telegram_links;
grant select on players_telegram to anon, authenticated;

-- Otomasyon: oyuncuyu Telegram sohbetine bağlar. Başarılıysa oyuncunun adını döndürür.
create or replace function bot_link_telegram(p_secret text, p_player uuid, p_chat bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare nm text;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  select nick into nm from players where id = p_player;
  if nm is null then return jsonb_build_object('ok', false, 'error', 'unknown_player'); end if;
  insert into telegram_links (player_id, chat_id) values (p_player, p_chat)
  on conflict (player_id) do update set chat_id = excluded.chat_id;
  return jsonb_build_object('ok', true, 'nick', nm);
end $$;

-- Otomasyon: kapanışına p_hours saat veya daha az kalan, tahmin girmemiş ve Telegram bağlamış oyuncuları listeler.
create or replace function bot_telegram_due(p_secret text, p_hours int default 2)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare res jsonb;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id', p.id, 'nick', p.nick, 'chat_id', l.chat_id,
    'match_id', m.id, 'home', m.home, 'away', m.away, 'comp', m.comp,
    'kickoff', m.kickoff, 'close_at', m.kickoff - interval '5 hours')), '[]'::jsonb)
  into res
  from matches m
  join telegram_links l on true
  join players p on p.id = l.player_id
  where m.kickoff - interval '5 hours' > now()
    and m.kickoff - interval '5 hours' <= now() + make_interval(hours => p_hours)
    and not exists (select 1 from predictions x where x.match_id = m.id and x.player_id = p.id)
    and not exists (select 1 from telegram_reminders r where r.match_id = m.id and r.player_id = p.id);
  return jsonb_build_object('ok', true, 'items', res);
end $$;

-- Otomasyon: gönderilen hatırlatmayı işaretler, tekrar gönderilmesin.
create or replace function bot_telegram_mark(p_secret text, p_match text, p_player uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  insert into telegram_reminders (match_id, player_id) values (p_match, p_player) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_link_telegram(text, uuid, bigint) to anon, authenticated;
grant execute on function bot_telegram_due(text, int) to anon, authenticated;
grant execute on function bot_telegram_mark(text, text, uuid) to anon, authenticated;
