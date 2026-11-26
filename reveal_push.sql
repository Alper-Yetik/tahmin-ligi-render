-- "Tahminler açıklandı" bildirimi. push.sql'den sonra çalıştır. Tekrar çalıştırılabilir.
-- Tahminler maça 5 saat kala herkese açılır. pg_cron her dakika reveal_push_tick()'i çalıştırır;
-- yeni açılan maç varsa chat-push Edge Function'ını çağırır, fonksiyon push_claim_reveals() ile
-- maçı alıp (bir kez) tüm abonelere bildirim gönderir.

create table if not exists push_reveals (
  match_id text primary key references matches(id) on delete cascade,
  sent_at timestamptz not null default now()
);
alter table push_reveals enable row level security;
revoke all on push_reveals from anon, authenticated;

-- Kurulumdan önce açılmış maçlar için bildirim gönderilmez.
insert into push_reveals (match_id)
  select id from matches where kickoff - interval '5 hours' <= now()
on conflict do nothing;

-- Son 3 saatte açılmış ve bildirimi gönderilmemiş maçları işaretleyip döndürür.
create or replace function push_claim_reveals()
returns table (id text, home text, away text, n int)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  return query
    with c as (
      insert into push_reveals (match_id)
        select m.id from matches m
        where m.kickoff - interval '5 hours' <= now() and m.kickoff - interval '5 hours' > now() - interval '3 hours'
          and not exists (select 1 from push_reveals r where r.match_id = m.id)
      on conflict do nothing
      returning match_id)
    select m.id, m.home, m.away, (select count(*)::int from predictions p where p.match_id = m.id)
    from c join matches m on m.id = c.match_id
    order by m.kickoff;
end $$;
revoke execute on function push_claim_reveals() from public, anon, authenticated;
grant execute on function push_claim_reveals() to service_role;

-- Sadece gerçekten yeni açılan maç varken fonksiyonu çağırır (her dakika boşuna çağrı olmasın).
create or replace function reveal_push_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from matches m
             where m.kickoff - interval '5 hours' <= now() and m.kickoff - interval '5 hours' > now() - interval '3 hours'
               and not exists (select 1 from push_reveals r where r.match_id = m.id)) then
    perform net.http_post(
      url := 'https://ecumfsoqquswjhphqciz.supabase.co/functions/v1/chat-push',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb);
  end if;
end $$;
revoke execute on function reveal_push_tick() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'reveal-push';
select cron.schedule('reveal-push', '* * * * *', 'select public.reveal_push_tick()');
