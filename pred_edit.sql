-- Tahmin değiştirme: her tahmin bir kez değiştirilebilir.
-- members.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Kapanış kuralı aynı: maça 5 saat kala tahmin girilemez ve değiştirilemez.
-- Telegram hatırlatmaları etkilenmez (tahmin girilmişse hatırlatma gitmez, değiştirmek bunu değiştirmez).

alter table predictions add column if not exists edited boolean not null default false;
alter table predictions add column if not exists edited_at timestamptz;

create or replace function change_prediction(p_token text, p_match text, p_h int, p_a int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); k timestamptz; cur predictions%rowtype;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_h is null or p_a is null or p_h not between 0 and 30 or p_a not between 0 and 30 then
    return jsonb_build_object('ok', false, 'error', 'invalid_score');
  end if;
  select kickoff into k from matches where id = p_match;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_match'); end if;
  if k - interval '5 hours' <= now() then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  select * into cur from predictions where match_id = p_match and player_id = pid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_prediction'); end if;
  if cur.edited then return jsonb_build_object('ok', false, 'error', 'already_edited'); end if;
  if cur.h = p_h and cur.a = p_a then return jsonb_build_object('ok', false, 'error', 'same_score'); end if;
  update predictions set h = p_h, a = p_a, edited = true, edited_at = now()
   where match_id = p_match and player_id = pid;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function change_prediction(text, text, int, int) to anon, authenticated;
