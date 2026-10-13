-- Sohbette "yazıyor…" göstergesi (WhatsApp gibi).
-- chat.sql ve members.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Site yazarken en çok 2,5 saniyede bir sinyal yollar. Son 5 saniyede yazmış ve ondan sonra mesaj
-- göndermemiş üyeler "yazıyor" sayılır. Süre sunucu saatine göre hesaplanır.

create table if not exists chat_typing (
  player_id uuid primary key references players(id) on delete cascade,
  at timestamptz not null default now()
);
alter table chat_typing enable row level security;
revoke all on chat_typing from anon, authenticated;

create or replace view chat_typing_public as
  select t.player_id, p.nick
  from chat_typing t
  join players p on p.id = t.player_id
  where t.at > now() - interval '5 seconds'
    and not exists (select 1 from chat_messages m where m.player_id = t.player_id and m.created_at >= t.at);
grant select on chat_typing_public to anon, authenticated;

-- Giriş yapmış üye "yazıyor" sinyali verir. Saniyede birden sık yazmaz (sessizce atlar).
create or replace function chat_typing(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := session_player(p_token);
begin
  if pid is null then return jsonb_build_object('ok', false, 'error', 'not_logged_in'); end if;
  insert into chat_typing (player_id, at) values (pid, now())
  on conflict (player_id) do update set at = now() where chat_typing.at < now() - interval '1 second';
  return jsonb_build_object('ok', true);
end $$;

grant execute on function chat_typing(text) to anon, authenticated;
