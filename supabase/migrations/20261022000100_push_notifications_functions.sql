-- Browser notifications for editors, part 2 of 2 (run after 20261022000000_push_notifications.sql, as its own query).
-- The trigger posts each visitor's new suggestion and the editors' devices to the site's /api/notify
-- (functions/api/notify.js), which sends the pushes. The site's address and the shared secret come from the Vault
-- (site_url, notify_secret: run build/vault.sql, which `python build.py` writes from .env). Safe to run again.

-- after a visitor's suggestion is saved: hand it to the site for sending. An editor's own changes (saved as
-- suggestions and approved at once) are not announced. A failure here never blocks the suggestion itself.
create or replace function public.notify_suggestion()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  subs   jsonb;
  secret text;
  site   text;
  who    text;
  other  text;
begin
  if is_admin() then
    return new;
  end if;
  begin
    subs := (select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) from push_subscriptions s);
    secret := (select v.decrypted_secret from vault.decrypted_secrets v where v.name = 'notify_secret' limit 1);
    site := (select rtrim(v.decrypted_secret, '/') from vault.decrypted_secrets v where v.name = 'site_url' limit 1);
    if subs is null or secret is null or site is null then
      return new;
    end if;
    if new.kind = 'add_root' then
      who := concat_ws(' ', new.changes ->> 'ime', new.changes ->> 'prezime');
    else
      who := (select concat_ws(' ', p.ime, p.prezime) from people p where p.id = new.person_id);
    end if;
    if new.kind = 'link' then
      other := (select concat_ws(' ', p.ime, p.prezime) from people p where p.id = (new.changes ->> 'brak_id')::integer);
    elsif new.kind = 'add_child' then
      other := concat_ws(' ', new.changes ->> 'ime', new.changes ->> 'prezime');   -- the new child's name
    end if;
    perform net.http_post(
      url     := site || '/api/notify',
      body    := jsonb_build_object('id', new.id, 'kind', new.kind, 'who', who, 'other', other, 'author', new.author, 'subs', subs),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', secret)
    );
  exception when others then
    raise warning 'notify_suggestion: %', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists suggestions_notify on public.suggestions;
create trigger suggestions_notify after insert on public.suggestions
  for each row execute function public.notify_suggestion();

-- the site reports devices that no longer exist (the browser dropped the subscription); it proves itself with the secret
create or replace function public.push_forget(secret text, endpoints text[])
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if secret is distinct from (select v.decrypted_secret from vault.decrypted_secrets v where v.name = 'notify_secret' limit 1) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from push_subscriptions where endpoint = any (endpoints);
end;
$$;

revoke execute on function public.push_forget(text, text[]) from public;
grant execute on function public.push_forget(text, text[]) to anon, authenticated;
revoke execute on function public.notify_suggestion() from public, anon, authenticated;
