-- İlk yarı (İY) skoru. live.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Raspberry'deki live_scores.py'ye dokunmaz: maç devre arasına girince (live_state = 'ht')
-- o anki canlı skor tetikleyiciyle ht_home / ht_away'e yazılır.

alter table matches add column if not exists ht_home int;
alter table matches add column if not exists ht_away int;

create or replace function matches_keep_ht() returns trigger language plpgsql as $$
begin
  if new.live_state = 'ht' and new.live_home is not null and new.live_away is not null then
    new.ht_home := new.live_home;
    new.ht_away := new.live_away;
  end if;
  return new;
end $$;

drop trigger if exists matches_keep_ht on matches;
create trigger matches_keep_ht before insert or update of live_state, live_home, live_away on matches
  for each row execute function matches_keep_ht();

-- Geçmiş maçlar: ESPN maç özetindeki ilk yarı skorları (20 Kasım 2026'da dolduruldu).
update matches set ht_home=1, ht_away=0 where id='gs1';
update matches set ht_home=0, ht_away=1 where id='fb1';
update matches set ht_home=2, ht_away=1 where id='bjk1';
update matches set ht_home=1, ht_away=1 where id='gs2';
update matches set ht_home=3, ht_away=0 where id='fb2';
update matches set ht_home=0, ht_away=0 where id='gs3';
update matches set ht_home=1, ht_away=0 where id='fb3';
update matches set ht_home=1, ht_away=0 where id='bjk3';
update matches set ht_home=2, ht_away=1 where id='fb-20261020-slavia';
update matches set ht_home=2, ht_away=2 where id='gs-20261021-lille';
update matches set ht_home=1, ht_away=0 where id='bjk-20261022-palace';
update matches set ht_home=0, ht_away=0 where id='bjk-20261026-basaksehir';
update matches set ht_home=2, ht_away=0 where id='gs-20261026-fb';
update matches set ht_home=0, ht_away=2 where id='gs-20261030-konya';
update matches set ht_home=1, ht_away=0 where id='fb-20261031-goztepe';
update matches set ht_home=0, ht_away=1 where id='bjk-20261101-kasimpasa';
update matches set ht_home=2, ht_away=0 where id='gs-20261103-stuttgart';
update matches set ht_home=1, ht_away=1 where id='fb-20261104-liverpool';
update matches set ht_home=0, ht_away=0 where id='bjk-20261105-celtic';
update matches set ht_home=2, ht_away=0 where id='gs-20261107-amed';
update matches set ht_home=0, ht_away=2 where id='fb-20261108-corum';
update matches set ht_home=2, ht_away=0 where id='bjk-20261108-genclerbirligi';
