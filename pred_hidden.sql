-- Tahmin gizliliği: bir maçın tahminleri, tahmin kapanışına (maça 5 saat kala) kadar başkalarından gizlenir.
-- Kim tahmin girdi bilgisi (kişi adı) açıktır, skorlar kapanışta herkese açılır. Tepkiler gizliyken de bırakılabilir.
-- chat_giphy.sql, pred_edit.sql ve pred_social.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- ÖNEMLİ: 1. ve 2. bölümü çalıştırıp siteyi yayınladıktan SONRA 3. bölümü (revoke) çalıştır;
-- aksi halde eski site sürümü tahminleri okuyamaz.

-- ---------- 1) Herkese açık görünüm: skorlar kapanışa kadar boş (null) ----------
create or replace view predictions_public as
  select p.match_id, p.player_id,
         (m.kickoff - interval '5 hours' <= now()) as revealed,
         case when m.kickoff - interval '5 hours' <= now() then p.h end as h,
         case when m.kickoff - interval '5 hours' <= now() then p.a end as a,
         p.edited as edited, -- değiştirdi bilgisi kilitliyken de görünür (skor ve eski skor gizli kalır)
         case when m.kickoff - interval '5 hours' <= now() then p.prev_h end as prev_h,
         case when m.kickoff - interval '5 hours' <= now() then p.prev_a end as prev_a
  from predictions p join matches m on m.id = p.match_id;
grant select on predictions_public to anon, authenticated;

-- ---------- 2) Üye kendi tahminlerini oturum anahtarıyla tam olarak okur ----------
create or replace function my_predictions(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('match_id', match_id, 'h', h, 'a', a, 'edited', edited, 'prev_h', prev_h, 'prev_a', prev_a))
    from predictions where player_id = pid), '[]'::jsonb));
end $$;
grant execute on function my_predictions(text) to anon, authenticated;

-- Sohbette alıntılanan tahmin de kapanışa kadar gizli (pred_hidden = true).
create or replace view chat_public as
  select m.id, m.player_id, p.nick, m.body, m.created_at, m.image,
         m.reply_to, rp.nick as reply_nick, r.body as reply_body, r.image as reply_image,
         (m.deleted_at is not null) as deleted, m.edited_at, (r.deleted_at is not null) as reply_deleted,
         m.pred_match, m.pred_player, pp.nick as pred_nick,
         case when mt.kickoff - interval '5 hours' <= now() then pr.h end as pred_h,
         case when mt.kickoff - interval '5 hours' <= now() then pr.a end as pred_a,
         mt.home as pred_home, mt.away as pred_away, mt.home_score as pred_hs, mt.away_score as pred_as,
         m.gif, r.gif as reply_gif,
         (pr.match_id is not null and mt.kickoff - interval '5 hours' > now()) as pred_hidden
  from chat_messages m
  join players p on p.id = m.player_id
  left join chat_messages r on r.id = m.reply_to
  left join players rp on rp.id = r.player_id
  left join players pp on pp.id = m.pred_player
  left join predictions pr on pr.match_id = m.pred_match and pr.player_id = m.pred_player
  left join matches mt on mt.id = m.pred_match;
grant select on chat_public to anon, authenticated;

-- ---------- 3) Tabloya doğrudan okuma kapanır (siteyi yayınladıktan SONRA çalıştır) ----------
-- revoke select on predictions from anon, authenticated;
