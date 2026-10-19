-- Merge a duplicated person (and their duplicated descendants) into one record.
--
--   select * from public.merge_people(keep_id, drop_id);                    -- dry run: lists what would happen
--   select * from public.merge_people(keep_id, drop_id, dry_run => false);  -- does it
--
-- The dropped person's children move to the kept person. Where both have a child with the same first name and
-- year of birth, those two are merged the same way, all the way down; of such a pair the older record (lower id,
-- usually the one from the book) is kept. Empty fields are filled from the dropped record; spouse, source and
-- note texts are combined; a differing occupation, place, nickname, surname or year stays as it was on the kept
-- record and the other value is added to the note. Marriage links and suggestions pointing at the dropped person
-- move to the kept one, and the dropped record is copied to deleted_people before it is deleted.
-- Run it in the SQL editor, or as a signed-in editor.

-- "a; b" unless b is empty or already part of a
create or replace function public.merge_text(a text, b text)
returns text language sql immutable as $$
  select case
    when nullif(btrim(b), '') is null then a
    when nullif(btrim(a), '') is null then b
    when position(lower(btrim(b)) in lower(a)) > 0 then a
    else a || '; ' || btrim(b)
  end;
$$;

create or replace function public.merge_people_step(k integer, d integer, log text[])
returns text[]
language plpgsql set search_path = public
as $$
declare
  a people;
  b people;
  dk people;
  kk people;
  extra text := null;
begin
  if k = d then raise exception 'a person cannot be merged into themself (%)', k; end if;
  select * into a from people where id = k for update;
  if not found then raise exception 'person % does not exist', k; end if;
  select * into b from people where id = d for update;
  if not found then raise exception 'person % does not exist', d; end if;
  if exists (with recursive up(pid) as (select a.roditelj_id union select p.roditelj_id from people p join up on p.id = up.pid)
             select 1 from up where pid = d) then
    raise exception '% (%) is a descendant of % (%): merge the other way round', a.ime, k, b.ime, d;
  end if;
  log := log || format('%s %s %s (%s): ostaje #%s, spaja se #%s', a.ime, coalesce(a.prezime, ''), coalesce(a.rodjen::text, '?'),
                       coalesce((select ime from people where id = a.roditelj_id), 'začetnik loze'), k, d);

  -- children of the dropped record: merge into a namesake of the same year, or move across
  for dk in select * from people where roditelj_id = d order by redosled, id loop
    select * into kk from people
      where roditelj_id = k and lower(btrim(ime)) = lower(btrim(dk.ime)) and rodjen is not distinct from dk.rodjen
      order by id limit 1;
    if found then
      if dk.id < kk.id then        -- keep the older record: it moves under k, then the newer one merges into it
        update people set roditelj_id = k, updated_at = now() where id = dk.id;
        log := merge_people_step(dk.id, kk.id, log);
      else
        log := merge_people_step(kk.id, dk.id, log);
      end if;
    else
      update people set roditelj_id = k, updated_at = now() where id = dk.id;
      log := log || format('  %s %s %s (#%s) prelazi pod #%s', dk.ime, coalesce(dk.prezime, ''), coalesce(dk.rodjen::text, '?'), dk.id, k);
    end if;
  end loop;

  -- details: fill the gaps, combine the free texts, note what disagrees
  if a.opis is not null and b.opis is not null and lower(a.opis) <> lower(b.opis) then extra := merge_text(extra, 'drugi zapis, zanimanje: ' || b.opis); end if;
  if a.mesto is not null and b.mesto is not null and lower(a.mesto) <> lower(b.mesto) then extra := merge_text(extra, 'drugi zapis, mesto: ' || b.mesto); end if;
  if a.nadimak is not null and b.nadimak is not null and lower(a.nadimak) <> lower(b.nadimak) then extra := merge_text(extra, 'drugi zapis, nadimak: ' || b.nadimak); end if;
  if a.prezime is not null and b.prezime is not null and lower(a.prezime) <> lower(b.prezime) then extra := merge_text(extra, 'drugi zapis, prezime: ' || b.prezime); end if;
  if a.rodjen is not null and b.rodjen is not null and a.rodjen <> b.rodjen then extra := merge_text(extra, 'drugi zapis, rođen: ' || b.rodjen); end if;
  update people set
    nadimak   = coalesce(a.nadimak, b.nadimak),
    prezime   = coalesce(a.prezime, b.prezime),
    rodjen    = coalesce(a.rodjen, b.rodjen),
    opis      = coalesce(a.opis, b.opis),
    mesto     = coalesce(a.mesto, b.mesto),
    supruznik = merge_text(a.supruznik, b.supruznik),
    izvor     = merge_text(a.izvor, b.izvor),
    napomena  = merge_text(merge_text(a.napomena, b.napomena), extra),
    pol       = coalesce(a.pol, b.pol),
    brak_id   = coalesce(a.brak_id, nullif(b.brak_id, k)),
    linija    = a.linija or b.linija,
    istaknuto = a.istaknuto or b.istaknuto,
    updated_at = now()
  where id = k;
  if extra is not null then log := log || format('  #%s napomena dobija: %s', k, extra); end if;

  -- whatever pointed at the dropped record now points at the kept one; then it goes
  update people set brak_id = k where brak_id = d and id <> k;
  update suggestions set person_id = k where person_id = d;
  insert into deleted_people select b.*, now(), auth.uid();
  delete from people where id = d;
  return log;
end;
$$;

create or replace function public.merge_people(keep_id integer, drop_id integer, dry_run boolean default true)
returns setof text
language plpgsql security definer set search_path = public
as $$
declare
  log text[] := '{}';
begin
  -- the SQL editor runs without a signed-in user; through the API only editors may merge
  if auth.uid() is not null and not is_admin() then
    raise exception 'only admins can merge people' using errcode = '42501';
  end if;
  begin
    log := merge_people_step(keep_id, drop_id, log);
    if dry_run then raise exception 'dry run' using errcode = 'P0D01'; end if;   -- undoes the block, keeps the log
  exception when sqlstate 'P0D01' then
    log := array_append(log, 'PROBNI PROLAZ: ništa nije sačuvano. Ako je spisak dobar, pokrenite ponovo sa dry_run => false.');
  end;
  return query select unnest(log);
end;
$$;

revoke execute on function public.merge_people_step(integer, integer, text[]) from public, anon, authenticated;
revoke execute on function public.merge_people(integer, integer, boolean) from public, anon;
grant execute on function public.merge_people(integer, integer, boolean) to authenticated;
