-- Anyone may suggest a new person with no parent (kind = 'add_root', no person_id).
-- Approving it inserts the person as a line founder; the page files them under their surname.

alter table public.suggestions alter column person_id drop not null;
alter table public.suggestions drop constraint suggestions_kind_check;
alter table public.suggestions
  add constraint suggestions_kind_check check (kind in ('edit', 'add_child', 'add_root')),
  add constraint root_has_no_person check ((kind = 'add_root') = (person_id is null));

create or replace function public.approve_suggestion(sid bigint, edited jsonb default null)
returns public.people
language plpgsql security definer set search_path = public
as $$
declare
  s suggestions;
  c jsonb;
  p people;
begin
  if not is_admin() then
    raise exception 'only admins can approve suggestions' using errcode = '42501';
  end if;
  select * into s from suggestions where id = sid for update;
  if not found or s.status <> 'pending' then
    raise exception 'suggestion % is not pending', sid;
  end if;
  c := coalesce(edited, s.changes);
  if s.kind in ('add_child', 'add_root') then
    if coalesce(btrim(c ->> 'ime'), '') = '' then
      raise exception 'a new person needs a first name';
    end if;
    -- a child goes after its existing siblings (children sort by redosled, then id); a founder has no parent
    insert into people (ime, nadimak, prezime, rodjen, opis, mesto, supruznik, izvor, napomena, pol, roditelj_id, redosled)
    values (btrim(c ->> 'ime'), nullif(btrim(c ->> 'nadimak'), ''), nullif(btrim(c ->> 'prezime'), ''),
            (nullif(btrim(c ->> 'rodjen'), ''))::integer, nullif(btrim(c ->> 'opis'), ''), nullif(btrim(c ->> 'mesto'), ''),
            nullif(btrim(c ->> 'supruznik'), ''), nullif(btrim(c ->> 'izvor'), ''), nullif(btrim(c ->> 'napomena'), ''),
            nullif(btrim(c ->> 'pol'), ''), s.person_id,
            case when s.kind = 'add_child'
                 then (select coalesce(max(redosled), 0) from people where roditelj_id = s.person_id) else 0 end)
    returning * into p;
  else
    update people set
      ime       = case when c ? 'ime'       then coalesce(nullif(btrim(c ->> 'ime'), ''), ime) else ime end,
      nadimak   = case when c ? 'nadimak'   then nullif(btrim(c ->> 'nadimak'), '')   else nadimak end,
      prezime   = case when c ? 'prezime'   then nullif(btrim(c ->> 'prezime'), '')   else prezime end,
      rodjen    = case when c ? 'rodjen'    then (nullif(btrim(c ->> 'rodjen'), ''))::integer else rodjen end,
      opis      = case when c ? 'opis'      then nullif(btrim(c ->> 'opis'), '')      else opis end,
      mesto     = case when c ? 'mesto'     then nullif(btrim(c ->> 'mesto'), '')     else mesto end,
      supruznik = case when c ? 'supruznik' then nullif(btrim(c ->> 'supruznik'), '') else supruznik end,
      izvor     = case when c ? 'izvor'     then nullif(btrim(c ->> 'izvor'), '')     else izvor end,
      napomena  = case when c ? 'napomena'  then nullif(btrim(c ->> 'napomena'), '')  else napomena end,
      pol       = case when c ? 'pol'       then nullif(btrim(c ->> 'pol'), '')       else pol end,
      updated_at = now()
    where id = s.person_id
    returning * into p;
  end if;
  update suggestions
    set status = 'approved', changes = c, reviewed_at = now(), reviewed_by = auth.uid()
    where id = sid;
  return p;
end;
$$;
