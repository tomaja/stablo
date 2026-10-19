-- Admins can add a person with no parent (a new line founder) and delete people.
-- Deleted rows are copied to deleted_people first, so a mistake can be undone from the SQL editor:
--   insert into public.people select <columns> from public.deleted_people where id = ...;

create table public.deleted_people (
  like public.people,
  deleted_at timestamptz not null default now(),
  deleted_by uuid
);
alter table public.deleted_people enable row level security;  -- no policies: readable only in the SQL editor

create function public.admin_create_person(data jsonb)
returns public.people
language plpgsql security definer set search_path = public
as $$
declare
  p people;
begin
  if not is_admin() then
    raise exception 'only admins can add people' using errcode = '42501';
  end if;
  if coalesce(btrim(data ->> 'ime'), '') = '' then
    raise exception 'a new person needs a first name';
  end if;
  insert into people (ime, nadimak, prezime, rodjen, opis, mesto, supruznik, izvor, napomena, pol)
  values (btrim(data ->> 'ime'), nullif(btrim(data ->> 'nadimak'), ''), nullif(btrim(data ->> 'prezime'), ''),
          (nullif(btrim(data ->> 'rodjen'), ''))::integer, nullif(btrim(data ->> 'opis'), ''), nullif(btrim(data ->> 'mesto'), ''),
          nullif(btrim(data ->> 'supruznik'), ''), nullif(btrim(data ->> 'izvor'), ''), nullif(btrim(data ->> 'napomena'), ''),
          nullif(btrim(data ->> 'pol'), ''))
  returning * into p;
  return p;
end;
$$;

-- with_descendants = false: the person's children move up to the person's own parent
-- (or become line founders); true: the whole branch goes. Returns how many people were deleted.
create function public.admin_delete_person(pid integer, with_descendants boolean default false)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  p people;
  ids integer[];
begin
  if not is_admin() then
    raise exception 'only admins can delete people' using errcode = '42501';
  end if;
  select * into p from people where id = pid for update;
  if not found then
    raise exception 'person % does not exist', pid;
  end if;
  if with_descendants then
    with recursive branch as (
      select id from people where id = pid
      union
      select c.id from people c join branch b on c.roditelj_id = b.id
    )
    select array_agg(id) into ids from branch;
  else
    ids := array[pid];
    update people set roditelj_id = p.roditelj_id, updated_at = now() where roditelj_id = pid;
  end if;
  insert into deleted_people
    select x.*, now(), auth.uid() from people x where x.id = any (ids);
  delete from people where id = any (ids);
  return cardinality(ids);
end;
$$;

revoke execute on function public.admin_create_person(jsonb), public.admin_delete_person(integer, boolean) from public, anon;
grant execute on function public.admin_create_person(jsonb), public.admin_delete_person(integer, boolean) to authenticated;
