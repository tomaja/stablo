-- A full snapshot of the data, taken inside Supabase. Run the whole file in the SQL editor (nothing highlighted).
-- The copies go to a separate schema, "backup", which the website's API does not serve, so suggestions with
-- visitors' contact details stay private. Each run makes a new set of tables named by date and time.

create schema if not exists backup;
revoke all on schema backup from public, anon, authenticated;

do $snap$
declare
  stamp text := to_char(now(), 'YYYYMMDD_HH24MI');
  t text;
begin
  foreach t in array array['people', 'suggestions', 'admins', 'deleted_people'] loop
    execute format('create table backup.%I as table public.%I', t || '_' || stamp, t);
  end loop;
  raise notice 'snapshot %', stamp;
end
$snap$;

-- what is in the backup schema now
select table_name,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from backup.%I', table_name), false, true, '')))[1]::text::int as rows
from information_schema.tables
where table_schema = 'backup'
order by table_name;

-- To put people back (example: a snapshot named 20261019_2330), run on its own. It updates everyone in place
-- rather than deleting the table first, because deleting a person also deletes their suggestions:
--   begin;
--   set constraints all deferred;
--   insert into public.people select * from backup.people_20261019_2330
--     on conflict (id) do update set ime = excluded.ime, nadimak = excluded.nadimak, prezime = excluded.prezime,
--       rodjen = excluded.rodjen, opis = excluded.opis, mesto = excluded.mesto, supruznik = excluded.supruznik,
--       redosled = excluded.redosled, linija = excluded.linija, istaknuto = excluded.istaknuto, izvor = excluded.izvor,
--       napomena = excluded.napomena, roditelj_id = excluded.roditelj_id, brak_id = excluded.brak_id, pol = excluded.pol,
--       updated_at = excluded.updated_at;
--   delete from public.people where id not in (select id from backup.people_20261019_2330);
--   select setval('public.people_id_seq', greatest(10000, (select max(id) + 1 from public.people)), false);
--   commit;
