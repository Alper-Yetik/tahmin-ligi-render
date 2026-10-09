-- Kartlar ve uzatma: Raspberry'deki live_scores.py yazar, site maç kartında gösterir.
-- live.sql çalıştırıldıktan sonra çalıştır.

alter table matches add column if not exists home_yellow int check (home_yellow >= 0);
alter table matches add column if not exists home_red int check (home_red >= 0);
alter table matches add column if not exists away_yellow int check (away_yellow >= 0);
alter table matches add column if not exists away_red int check (away_red >= 0);
-- Dördüncü hakemin gösterdiği uzatma süresi (dakika). Devre değişince betik günceller ya da temizler.
alter table matches add column if not exists live_added int check (live_added between 0 and 30);

-- Maç başladıktan sonraki 8 saat boyunca kart ve uzatma bilgisini yazar. Kesin skor yazılmış olsa bile
-- kartlar kalıcı olarak güncellenebilir, çünkü son dakikalardaki kart maç bittikten sonra da işlenmeli.
create or replace function bot_set_extra(p_secret text, p_id text, p_hy int, p_hr int, p_ay int, p_ar int, p_added int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c int;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_hy is null or p_hr is null or p_ay is null or p_ar is null
     or p_hy not between 0 and 30 or p_hr not between 0 and 30 or p_ay not between 0 and 30 or p_ar not between 0 and 30
     or (p_added is not null and p_added not between 0 and 30) then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update matches
     set home_yellow = p_hy, home_red = p_hr, away_yellow = p_ay, away_red = p_ar, live_added = p_added
   where id = p_id
     and kickoff - interval '30 minutes' < now()
     and kickoff + interval '8 hours' > now();
  get diagnostics c = row_count;
  if c = 0 then return jsonb_build_object('ok', false, 'error', 'not_updated'); end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_set_extra(text, text, int, int, int, int, int) to anon, authenticated;
