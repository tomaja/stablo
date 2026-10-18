-- Family tree data + moderated edit suggestions.
--
-- people       public read; nobody writes directly (changes go through approve_suggestion)
-- suggestions  anyone may insert a pending suggestion; only admins can read or decide them
-- admins       e-mail addresses allowed to approve; add yours after running this file

create table public.people (
  id          integer primary key,
  ime         text not null,
  nadimak     text,
  prezime     text,
  rodjen      integer check (rodjen between 1000 and 2100),
  opis        text,
  mesto       text,
  supruznik   text,
  redosled    integer not null default 0,
  linija      boolean not null default false,
  istaknuto   boolean not null default false,
  izvor       text,
  napomena    text,
  roditelj_id integer references public.people (id) on delete set null deferrable initially deferred,
  brak_id     integer references public.people (id) on delete set null deferrable initially deferred,
  pol         text check (pol in ('m', 'f')),
  updated_at  timestamptz not null default now()
);
create index people_roditelj_idx on public.people (roditelj_id);

create table public.admins (
  email text primary key
);

create table public.suggestions (
  id          bigint generated always as identity primary key,
  person_id   integer not null references public.people (id) on delete cascade,
  changes     jsonb not null,
  original    jsonb,
  author      text check (char_length(author) <= 100),
  contact     text check (char_length(contact) <= 200),
  comment     text check (char_length(comment) <= 2000),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  constraint changes_shape check (
    jsonb_typeof(changes) = 'object'
    and changes <> '{}'::jsonb
    and changes - array['ime', 'nadimak', 'prezime', 'rodjen', 'opis', 'mesto', 'supruznik', 'izvor', 'napomena', 'pol'] = '{}'::jsonb
    and pg_column_size(changes) < 20000
  )
);
create index suggestions_pending_idx on public.suggestions (created_at) where status = 'pending';

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- row level security
alter table public.people enable row level security;
alter table public.admins enable row level security;       -- no policies: only security-definer functions read it
alter table public.suggestions enable row level security;

create policy "people are public" on public.people for select using (true);

create policy "anyone can suggest" on public.suggestions for insert to anon, authenticated
  with check (status = 'pending');
create policy "admins read suggestions" on public.suggestions for select to authenticated
  using (public.is_admin());

-- visitors may only fill in the suggestion itself, not its status or review fields
revoke insert, update, delete on public.suggestions from anon, authenticated;
grant insert (person_id, changes, original, author, contact, comment) on public.suggestions to anon, authenticated;
revoke insert, update, delete on public.people from anon, authenticated;

-- apply a pending suggestion to the person; `edited` lets the admin adjust the values first
create function public.approve_suggestion(sid bigint, edited jsonb default null)
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
  update suggestions
    set status = 'approved', changes = c, reviewed_at = now(), reviewed_by = auth.uid()
    where id = sid;
  return p;
end;
$$;

create function public.reject_suggestion(sid bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'only admins can reject suggestions' using errcode = '42501';
  end if;
  update suggestions
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
    where id = sid and status = 'pending';
  if not found then
    raise exception 'suggestion % is not pending', sid;
  end if;
end;
$$;

revoke execute on function public.approve_suggestion(bigint, jsonb), public.reject_suggestion(bigint) from public, anon;
grant execute on function public.approve_suggestion(bigint, jsonb), public.reject_suggestion(bigint) to authenticated;

-- Then, with your own address (the account you will sign in with):
--   insert into public.admins (email) values ('you@example.com');
