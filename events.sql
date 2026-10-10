-- Gol ve kart olayları (oyuncu adlarıyla): live_scores.py yazar, site maç kartında listeler.
-- extra.sql çalıştırıldıktan sonra Supabase SQL Editor'de bir kez çalıştır.
-- Biçim: [{"k":"goal|pen|own|yellow|red","m":"45'+2'","p":"Oyuncu","s":"home|away"}]

alter table matches add column if not exists live_events jsonb;

create or replace function bot_set_events(p_secret text, p_id text, p_events jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c int;
begin
  if not bot_ok(p_secret) then return jsonb_build_object('ok', false, 'error', 'wrong_secret'); end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 60 then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;
  update matches set live_events = p_events
   where id = p_id
     and kickoff - interval '30 minutes' < now()
     and kickoff + interval '8 hours' > now();
  get diagnostics c = row_count;
  if c = 0 then return jsonb_build_object('ok', false, 'error', 'not_updated'); end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function bot_set_events(text, text, jsonb) to anon, authenticated;
