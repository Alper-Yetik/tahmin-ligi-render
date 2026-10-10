-- Puan durumları: Raspberry'deki sync_standings.py ESPN'den çekip yazar, site "Süper Lig" ve "Avrupa" sekmelerinde gösterir.
-- bot.sql çalıştırıldıktan sonra Supabase SQL Editor'de bir kez çalıştır.
-- league: super | ucl | uel | uecl
-- data: [{"r":1,"t":"Galatasaray","o":5,"w":4,"d":1,"l":0,"gf":13,"ga":6,"gd":7,"p":13,"c":"#81D6AC","n":"Champions League"}]

create table if not exists standings (
  league text primary key check (league in ('super', 'ucl', 'uel', 'uecl')),
  season text,
  data jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table standings enable row level security;
revoke all on standings from anon, authenticated;
grant select on standings to anon, authenticated;
drop policy if exists standings_read on standings;
create policy standings_read on standings for select to anon, authenticated using (true);

create or replace function bot_set_standings(p_secret text, p_league text, p_season text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_league not in ('super', 'ucl', 'uel', 'uecl')
     or p_data is null or jsonb_typeof(p_data) <> 'array' or jsonb_array_length(p_data) > 80 then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  insert into standings (league, season, data, updated_at)
  values (p_league, left(coalesce(p_season, ''), 20), p_data, now())
  on conflict (league) do update set season = excluded.season, data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_set_standings(text, text, text, jsonb) to anon, authenticated;
