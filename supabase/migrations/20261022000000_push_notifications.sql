-- Browser notifications for editors, part 1 of 2: where editors' devices are stored. Each new suggestion from a
-- visitor is pushed to every device an editor turned notifications on for (part 2 has the trigger that does it).
--
-- Run in the SQL editor in this order, each as its own query (nothing highlighted):
--   1. build/vault.sql   (written by `python build.py` from .env: stores the site's address and the shared secret in
--                        the Vault; git-ignored, holds the secret)
--   2. this file
--   3. 20261022000100_push_notifications_functions.sql
-- The parts are separate because the editor's "table without RLS" check cuts off function bodies that follow a
-- create table in the same query. Safe to run again.

create extension if not exists pg_net;

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  email      text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

-- an editor sees and changes only their own devices
drop policy if exists "editors manage their own devices" on public.push_subscriptions;
create policy "editors manage their own devices" on public.push_subscriptions for all to authenticated
  using (public.is_admin() and lower(email) = lower(auth.jwt() ->> 'email'))
  with check (public.is_admin() and lower(email) = lower(auth.jwt() ->> 'email'));
grant select, insert, update, delete on public.push_subscriptions to authenticated;
