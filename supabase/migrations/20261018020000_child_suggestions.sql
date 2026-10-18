-- Suggestions can also propose a new child: kind = 'add_child', person_id = the parent,
-- changes = the new person's fields. Approving inserts the child under that parent.

-- people added through the site get ids from 10000 up (build.py's hand-added people use 9001+)
create sequence public.people_id_seq owned by public.people.id;
select setval('public.people_id_seq', greatest(10000, (select coalesce(max(id), 0) + 1 from public.people)), false);
alter table public.people alter column id set default nextval('public.people_id_seq');

alter table public.suggestions
  add column kind text not null default 'edit' check (kind in ('edit', 'add_child')),
  add constraint child_has_name check (kind = 'edit' or coalesce(btrim(changes ->> 'ime'), '') <> '');
grant insert (kind) on public.suggestions to anon, authenticated;

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
  if s.kind = 'add_child' then
    if coalesce(btrim(c ->> 'ime'), '') = '' then
      raise exception 'a new child needs a first name';
    end if;
    -- after the existing siblings: children sort by redosled, then id
    insert into people (ime, nadimak, prezime, rodjen, opis, mesto, supruznik, izvor, napomena, pol, roditelj_id, redosled)
    values (btrim(c ->> 'ime'), nullif(btrim(c ->> 'nadimak'), ''), nullif(btrim(c ->> 'prezime'), ''),
            (nullif(btrim(c ->> 'rodjen'), ''))::integer, nullif(btrim(c ->> 'opis'), ''), nullif(btrim(c ->> 'mesto'), ''),
            nullif(btrim(c ->> 'supruznik'), ''), nullif(btrim(c ->> 'izvor'), ''), nullif(btrim(c ->> 'napomena'), ''),
            nullif(btrim(c ->> 'pol'), ''), s.person_id,
            (select coalesce(max(redosled), 0) from people where roditelj_id = s.person_id))
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
