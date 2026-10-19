// Back up the people table from Supabase to backups/ (needs SUPABASE_URL and SUPABASE_KEY in .env).
//
//   node backup.mjs
//
// Writes, named by date and time:
//   backups/people-<stamp>.json         every row as it is in the database
//   backups/people-<stamp>-restore.sql  SQL that puts the table back exactly as it was (run it in the SQL editor)
//
// The public key can read only the people table. Suggestions, editors and deleted_people need a snapshot taken
// inside Supabase (see supabase/scripts/snapshot.sql).
import fs from 'node:fs';
import path from 'node:path';

const root = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const env = {};
for (const line of fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/)) {
  const i = line.indexOf('=');
  if (i > 0 && !line.trim().startsWith('#')) env[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, '');
}
const url = (env.SUPABASE_URL || '').replace(/\/+$/, '').replace(/\/rest\/v1$/, ''), key = env.SUPABASE_KEY;
if (!url || !key) { console.error('Set SUPABASE_URL and SUPABASE_KEY in .env'); process.exit(1); }
const headers = { apikey: key, Authorization: 'Bearer ' + key };

const COLS = ['id', 'ime', 'nadimak', 'prezime', 'rodjen', 'opis', 'mesto', 'supruznik', 'redosled', 'linija', 'istaknuto',
  'izvor', 'napomena', 'roditelj_id', 'brak_id', 'pol', 'updated_at'];

const rows = [];
const first = await fetch(`${url}/rest/v1/people?select=${COLS.join(',')}&order=id`, { headers: { ...headers, Range: '0-999', Prefer: 'count=exact' } });
if (!first.ok) { console.error('Could not read people:', first.status, await first.text()); process.exit(1); }
const total = +((first.headers.get('content-range') || '').split('/')[1] || 0);
rows.push(...await first.json());
for (let from = rows.length; from < total; from += 1000) {
  const r = await fetch(`${url}/rest/v1/people?select=${COLS.join(',')}&order=id`, { headers: { ...headers, Range: `${from}-${from + 999}` } });
  if (!r.ok) { console.error('Could not read people:', r.status, await r.text()); process.exit(1); }
  rows.push(...await r.json());
}
if (rows.length !== total) { console.error(`Expected ${total} rows, got ${rows.length}`); process.exit(1); }

const stamp = new Date().toISOString().slice(0, 16).replace(/[-:]/g, '').replace('T', '-');
const dir = path.join(root, 'backups');
fs.mkdirSync(dir, { recursive: true });
const json = path.join(dir, `people-${stamp}.json`);
fs.writeFileSync(json, JSON.stringify({ table: 'people', taken: new Date().toISOString(), count: rows.length, rows }, null, 1));

const lit = v => v == null ? 'null' : typeof v === 'boolean' ? String(v) : typeof v === 'number' ? String(v) : `'${String(v).replace(/'/g, "''")}'`;
// Restore in place rather than delete-and-reinsert: deleting a person deletes their suggestions with them, so
// every person in the backup is updated (or re-added) and only people added since are removed.
const sql = [
  `-- Restores public.people to the backup taken ${new Date().toISOString()} (${rows.length} people).`,
  '-- Everyone in the backup gets their details back, anyone missing is re-added, and people added since the',
  '-- backup are removed (with their suggestions). Suggestions about people in the backup are kept.',
  'begin;',
  'set constraints all deferred;',
];
const upd = COLS.filter(c => c !== 'id').map(c => `${c} = excluded.${c}`).join(', ');
for (let i = 0; i < rows.length; i += 500) {
  sql.push(`insert into public.people (${COLS.join(', ')}) values`);
  sql.push(rows.slice(i, i + 500).map(r => '(' + COLS.map(c => lit(r[c])).join(', ') + ')').join(',\n')
    + `\non conflict (id) do update set ${upd};`);
}
sql.push(`delete from public.people where id <> all (array[${rows.map(r => r.id).join(',')}]);`);
sql.push("select setval('public.people_id_seq', greatest(10000, (select max(id) + 1 from public.people)), false);");
sql.push('commit;');
const restore = path.join(dir, `people-${stamp}-restore.sql`);
fs.writeFileSync(restore, sql.join('\n') + '\n');

console.log(`${rows.length} people backed up`);
console.log(' ', path.relative(root, json), `(${Math.round(fs.statSync(json).size / 1024)} KB)`);
console.log(' ', path.relative(root, restore), `(${Math.round(fs.statSync(restore).size / 1024)} KB)`);
