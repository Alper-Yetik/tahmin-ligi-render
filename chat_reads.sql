-- Sohbette okundu bilgisi (WhatsApp'taki tikler gibi).
-- chat.sql ve members.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Her üye için "okuduğu en son mesaj" tutulur. Sohbet açıkken site bunu günceller.
-- Bir mesajı, numarası bu değere eşit ya da küçük olan üyeler okumuş sayılır.

create table if not exists chat_reads (
  player_id uuid primary key references players(id) on delete cascade,
  last_id bigint not null,
  at timestamptz not null default now()
);
alter table chat_reads enable row level security;
revoke all on chat_reads from anon, authenticated;

-- Herkes okuyabilir. Son 14 gündür sohbeti açmayanlar "herkes okudu" hesabına katılmaz.
create or replace view chat_reads_public as
  select r.player_id, p.nick, r.last_id
  from chat_reads r
  join players p on p.id = r.player_id
  where r.at > now() - interval '14 days';
grant select on chat_reads_public to anon, authenticated;

-- Giriş yapmış üye okuduğu son mesajı bildirir. Geriye gitmez, var olan son mesajın ötesine geçmez.
create or replace function chat_mark_read(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token); mx bigint;
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  if p_id is null or p_id < 1 then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  select max(id) into mx from chat_messages;
  if mx is null then return jsonb_build_object('ok', true); end if;
  p_id := least(p_id, mx);
  insert into chat_reads (player_id, last_id) values (pid, p_id)
  on conflict (player_id) do update set last_id = excluded.last_id, at = now()
    where excluded.last_id > chat_reads.last_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function chat_mark_read(text, bigint) to anon, authenticated;
