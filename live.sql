-- Canlı skor: Raspberry'deki live_scores.py her dakika yazar, site canlı puan durumunu gösterir.
-- bot.sql çalıştırıldıktan sonra çalıştır.

alter table matches add column if not exists live_home int check (live_home >= 0);
alter table matches add column if not exists live_away int check (live_away >= 0);
alter table matches add column if not exists live_minute text;
alter table matches add column if not exists live_state text check (live_state in ('live', 'ht', 'ft'));
alter table matches add column if not exists live_updated timestamptz;

-- Sadece başlamış, henüz kesin skoru girilmemiş maça canlı skor yazar. Kesin skora dokunmaz.
create or replace function bot_set_live(p_secret text, p_id text, p_hs int, p_as int, p_minute text, p_state text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c int;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_hs is null or p_as is null or p_hs < 0 or p_as < 0 or p_state not in ('live', 'ht', 'ft') then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update matches
     set live_home = p_hs, live_away = p_as, live_minute = left(coalesce(p_minute, ''), 12),
         live_state = p_state, live_updated = now()
   where id = p_id
     and home_score is null and away_score is null
     and kickoff - interval '30 minutes' < now()
     and kickoff + interval '6 hours' > now();
  get diagnostics c = row_count;
  if c = 0 then return jsonb_build_object('ok', false, 'error', 'not_updated'); end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_set_live(text, text, int, int, text, text) to anon, authenticated;
