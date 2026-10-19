-- merge_people, second version of the step that does the work. Changes from 20261020000000:
--   * children match on first name when their years agree OR one of them has no year (the book often leaves
--     grandchildren without one); an exact year is still preferred
--   * a different first name is kept in the note ("drugi zapis, ime: Ljiljana") instead of being lost
--   * a surname of "?" counts as empty: it is filled from the other record and not noted as a difference
-- Run the whole file once in the SQL editor (nothing highlighted). merge_people itself is unchanged.

create or replace function public.merge_people_step(k integer, d integer, log text[])
returns text[]
language plpgsql set search_path = public
as $step$
declare
  a people;
  b people;
  dk people;
  kk people;
  extra text := null;
  a_prez text;
  b_prez text;
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
  log := log || format('%s %s %s (%s): ostaje #%s, spaja se #%s (%s %s)', a.ime, coalesce(a.prezime, ''), coalesce(a.rodjen::text, '?'),
                       coalesce((select ime from people where id = a.roditelj_id), 'začetnik loze'), k, d, b.ime, coalesce(b.rodjen::text, '?'));

  -- children of the dropped record: merge into a namesake (same year, or a year missing on either side), or move across
  for dk in select * from people where roditelj_id = d order by redosled, id loop
    select * into kk from people
      where roditelj_id = k and lower(btrim(ime)) = lower(btrim(dk.ime))
        and (rodjen is not distinct from dk.rodjen or rodjen is null or dk.rodjen is null)
      order by (rodjen is not distinct from dk.rodjen) desc, id limit 1;
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
  a_prez := nullif(btrim(a.prezime), '?');
  b_prez := nullif(btrim(b.prezime), '?');
  if lower(btrim(a.ime)) <> lower(btrim(b.ime)) and nullif(btrim(b.ime), '?') is not null then extra := merge_text(extra, 'drugi zapis, ime: ' || b.ime); end if;
  if a.opis is not null and b.opis is not null and lower(a.opis) <> lower(b.opis) then extra := merge_text(extra, 'drugi zapis, zanimanje: ' || b.opis); end if;
  if a.mesto is not null and b.mesto is not null and lower(a.mesto) <> lower(b.mesto) then extra := merge_text(extra, 'drugi zapis, mesto: ' || b.mesto); end if;
  if a.nadimak is not null and b.nadimak is not null and lower(a.nadimak) <> lower(b.nadimak) then extra := merge_text(extra, 'drugi zapis, nadimak: ' || b.nadimak); end if;
  if a_prez is not null and b_prez is not null and lower(a_prez) <> lower(b_prez) then extra := merge_text(extra, 'drugi zapis, prezime: ' || b_prez); end if;
  if a.rodjen is not null and b.rodjen is not null and a.rodjen <> b.rodjen then extra := merge_text(extra, 'drugi zapis, rođen: ' || b.rodjen); end if;
  update people set
    nadimak   = coalesce(a.nadimak, b.nadimak),
    prezime   = coalesce(a_prez, b_prez, a.prezime),
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
$step$;

revoke execute on function public.merge_people_step(integer, integer, text[]) from public, anon, authenticated;
