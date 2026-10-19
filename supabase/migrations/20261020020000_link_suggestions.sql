-- Anyone may suggest that two people in the tree are married (kind = 'link'): person_id is one spouse and
-- changes = {"brak_id": <the other spouse's id>}. Approving it sets people.brak_id, which the site shows on both
-- people as "Brak u stablu" and as a dashed line between them in the tree.

alter table public.suggestions
  drop constraint suggestions_kind_check,
  drop constraint changes_shape,
  drop constraint child_has_name;
alter table public.suggestions
  add constraint suggestions_kind_check check (kind in ('edit', 'add_child', 'add_root', 'link')),
  add constraint changes_shape check (
    jsonb_typeof(changes) = 'object'
    and changes <> '{}'::jsonb
    and changes - array['ime', 'nadimak', 'prezime', 'rodjen', 'opis', 'mesto', 'supruznik', 'izvor', 'napomena', 'pol', 'brak_id'] = '{}'::jsonb
    and pg_column_size(changes) < 20000
  ),
  add constraint child_has_name check (kind in ('edit', 'link') or coalesce(btrim(changes ->> 'ime'), '') <> ''),
  -- a link carries exactly one id, and nothing else carries brak_id
  add constraint link_shape check (
    (kind = 'link') = (changes ? 'brak_id')
    and (kind <> 'link' or (changes - 'brak_id' = '{}'::jsonb and jsonb_typeof(changes -> 'brak_id') = 'number'))
  );

create or replace function public.approve_suggestion(sid bigint, edited jsonb default null)
returns public.people
language plpgsql security definer set search_path = public
as $$
declare
  s suggestions;
  c jsonb;
  p people;
  spouse integer;
begin
  if not is_admin() then
    raise exception 'only admins can approve suggestions' using errcode = '42501';
  end if;
  -- lock the row, then read it (rows are read by assignment: the SQL editor misreads the other form as a new table)
  perform 1 from suggestions where id = sid for update;
  s := (select x from suggestions x where x.id = sid);
  if s.id is null or s.status <> 'pending' then
    raise exception 'suggestion % is not pending', sid;
  end if;
  c := coalesce(edited, s.changes);
  if s.kind = 'link' then
    spouse := (c ->> 'brak_id')::integer;
    if spouse = s.person_id then
      raise exception 'a person cannot be married to themself';
    end if;
    if not exists (select 1 from people where id = spouse) then
      raise exception 'the spouse (#%) is no longer in the tree', spouse;
    end if;
    update people set brak_id = spouse, updated_at = now() where id = s.person_id;
    p := (select x from people x where x.id = s.person_id);
  elsif s.kind in ('add_child', 'add_root') then
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
                 then (select coalesce(max(redosled), 0) from people where roditelj_id = s.person_id) else 0 end);
    p := (select x from people x where x.id = currval('public.people_id_seq'));   -- the row just added
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
    where id = s.person_id;
    p := (select x from people x where x.id = s.person_id);
  end if;
  update suggestions
    set status = 'approved', changes = c, reviewed_at = now(), reviewed_by = auth.uid()
    where id = sid;
  return p;
end;
$$;
