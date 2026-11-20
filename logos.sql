-- Takım logoları: sitedeki takım adı -> ESPN takım kimliği. Logo adresi sitede kurulur:
-- https://a.espncdn.com/i/teamlogos/soccer/500/<espn_id>.png
-- schema.sql ve bot.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Yeni rakipleri Raspberry'deki sync_fixtures.py maç eklerken bot_upsert_logo ile ekler.

create table if not exists team_logos (
  name text primary key,
  espn_id text not null check (espn_id ~ '^[0-9]{1,9}$'),
  updated_at timestamptz not null default now()
);
alter table team_logos enable row level security;
grant select on team_logos to anon, authenticated;
drop policy if exists team_logos_read on team_logos;
create policy team_logos_read on team_logos for select to anon, authenticated using (true);

create or replace function bot_upsert_logo(p_secret text, p_name text, p_espn_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_name is null or char_length(p_name) not between 1 and 80 or p_espn_id !~ '^[0-9]{1,9}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  insert into team_logos (name, espn_id) values (p_name, p_espn_id)
  on conflict (name) do update set espn_id = excluded.espn_id, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;
grant execute on function bot_upsert_logo(text, text, text) to anon, authenticated;

insert into team_logos (name, espn_id) values
  ('AEK Athens', '887'),
  ('Alanyaspor', '9078'),
  ('Amed SFK', '132335'),
  ('Aston Villa', '362'),
  ('Atlético Madrid', '1068'),
  ('Barcelona', '83'),
  ('Bayer Leverkusen', '131'),
  ('Beşiktaş', '1895'),
  ('Celtic', '256'),
  ('Crystal Palace', '384'),
  ('Erzurum BB', '19267'),
  ('Eyüpspor', '20729'),
  ('Fenerbahçe', '436'),
  ('Feyenoord Rotterdam', '142'),
  ('Galatasaray', '432'),
  ('Gaziantep FK', '20070'),
  ('Gençlerbirliği', '996'),
  ('Göztepe', '789'),
  ('Hapoel Beer Sheva', '13083'),
  ('Hoffenheim', '7911'),
  ('Kasımpaşa', '6870'),
  ('Kocaelispor', '995'),
  ('Konyaspor', '7648'),
  ('LASK Linz', '4411'),
  ('Lille', '166'),
  ('Liverpool', '364'),
  ('Omonia Nicosia', '617'),
  ('Paris Saint-Germain', '160'),
  ('Samsunspor', '11429'),
  ('Shakhtar Donetsk', '493'),
  ('Slavia Prague', '494'),
  ('Trabzonspor', '997'),
  ('Union St.-Gilloise', '5807'),
  ('VfB Stuttgart', '134'),
  ('Villarreal', '102'),
  ('Çaykur Rizespor', '7656'),
  ('Çorum FK', '132334'),
  ('İstanbul Başakşehir', '7914')
on conflict (name) do update set espn_id = excluded.espn_id, updated_at = now();
