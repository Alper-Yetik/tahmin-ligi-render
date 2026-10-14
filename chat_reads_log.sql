-- "Ne zaman okudu" bilgisi: her üyenin okuma ilerlemesi zamanıyla birlikte kaydedilir.
-- chat_reads.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Bir üyenin bir mesajı okuma zamanı = okuma ilerlemesinin o mesaja ya da ötesine ilk ulaştığı an.
-- Bu dosyadan önceki okumalar için kesin zaman yoktur; en eski kayıt olarak üyenin son okuma zamanı kullanılır.

create table if not exists chat_read_log (
  player_id uuid not null references players(id) on delete cascade,
  last_id bigint not null,
  at timestamptz not null default now()
);
create index if not exists chat_read_log_idx on chat_read_log (last_id, player_id);
alter table chat_read_log enable row level security;
revoke all on chat_read_log from anon, authenticated;

-- Mevcut okuma durumunu başlangıç kaydı olarak aktar (sadece tablo boşken).
insert into chat_read_log (player_id, last_id, at)
select player_id, last_id, at from chat_reads
where not exists (select 1 from chat_read_log);

create or replace view chat_read_log_public as
  select l.player_id, p.nick, l.last_id, l.at
  from chat_read_log l join players p on p.id = l.player_id
  where l.at > now() - interval '60 days';
grant select on chat_read_log_public to anon, authenticated;

create or replace function chat_mark_read(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); mx bigint; adv int;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_id is null or p_id < 1 then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  select max(id) into mx from chat_messages;
  if mx is null then return jsonb_build_object('ok', true); end if;
  p_id := least(p_id, mx);
  with up as (
    insert into chat_reads (player_id, last_id) values (pid, p_id)
    on conflict (player_id) do update set last_id = excluded.last_id, at = now()
      where excluded.last_id > chat_reads.last_id
    returning 1)
  select count(*) into adv from up;
  if adv > 0 then
    insert into chat_read_log (player_id, last_id) values (pid, p_id);
    delete from chat_read_log where at < now() - interval '60 days';
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function chat_mark_read(text, bigint) to anon, authenticated;
