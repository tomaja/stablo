// POST /api/notify: Supabase calls this for each new suggestion (trigger notify_suggestion, see
// supabase/migrations/20261022000000_push_notifications.sql) with the suggestion and the editors' devices.
// Secrets of the Pages project: NOTIFY_SECRET (shared with Supabase's Vault), VAPID_PRIVATE_JWK, SUPABASE_URL, SUPABASE_KEY.
import { send } from '../../lib/webpush.js';

const KIND = { edit: 'Izmena', add_child: 'Novo dete', add_root: 'Nova osoba bez roditelja', link: 'Povezivanje braka' };

function message(s) {
  const what = s.kind === 'link' ? [s.who, s.other].filter(Boolean).join(' ∞ ')
    : s.kind === 'add_child' ? [s.other, s.who ? `dete osobe ${s.who}` : ''].filter(Boolean).join(', ')
    : s.who;
  return JSON.stringify({
    title: `Novi predlog · ${KIND[s.kind] || s.kind}`,
    body: [what, s.author ? `predložio/la: ${s.author}` : ''].filter(Boolean).join('\n'),
    tag: `suggestion-${s.id}`,
    url: './#review'
  });
}

export async function onRequestPost({ request, env }) {
  if (!env.NOTIFY_SECRET || request.headers.get('x-notify-secret') !== env.NOTIFY_SECRET) return new Response('forbidden', { status: 403 });
  const s = await request.json();
  const subs = Array.isArray(s.subs) ? s.subs : [];
  const jwk = JSON.parse(env.VAPID_PRIVATE_JWK), text = message(s), gone = [];
  let sent = 0;
  await Promise.all(subs.map(async sub => {
    try {
      const r = await send(sub, text, jwk, 'https://rodoslov.pages.dev');
      if (r.status === 404 || r.status === 410) gone.push(sub.endpoint);
      else if (r.ok) sent++;
      else console.error('push', r.status, await r.text());
    } catch (e) { console.error('push', e); }
  }));
  // the browser dropped these subscriptions: forget them
  if (gone.length && env.SUPABASE_URL && env.SUPABASE_KEY) {
    await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/push_forget`, {
      method: 'POST', headers: { apikey: env.SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ secret: env.NOTIFY_SECRET, endpoints: gone })
    }).catch(e => console.error('push_forget', e));
  }
  return Response.json({ sent, gone: gone.length, of: subs.length });
}
