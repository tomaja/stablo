# Rodoslov

[English](#english) · [Srpski](#srpski)

## English

Family-tree site for the families of Mali and Veliki Cvjetnić. Visitors browse the tree and suggest
changes; editors sign in to approve them.

### How it fits together

- **Supabase** holds the data (`people`, `suggestions`, `admins`, `push_subscriptions`), editors'
  sign-in (e-mail and password) and the database functions that approve, merge and delete people.
  Row-level security means the public key can read people and file suggestions, and nothing more.
- **Cloudflare Pages** serves the static pages that `build.py` writes to `site/`, plus one Pages
  Function, `functions/api/notify.js` (served at `/api/notify`).
- **Notifications.** When a visitor files a suggestion, a database trigger posts it to `/api/notify`
  through `pg_net`, along with a shared secret. The function then sends a Web Push to every device
  where an editor turned notifications on.

The page has no server of its own: `build.py` bakes the Supabase URL and public key into the HTML,
and the browser talks to Supabase directly.

| Path | What it is |
| --- | --- |
| `build.py` | builds `site/`; also turns `export.xlsx` (the source spreadsheet, kept out of git) into `supabase/seed.sql` |
| `src/` | page templates (`template.html` for desktop, `phone.html` for phones), service worker, manifest, icons |
| `functions/api/notify.js`, `lib/webpush.js` | the Pages Function that sends notifications |
| `supabase/migrations/` | database schema, in the order to run it |
| `supabase/seed.sql` | everyone from the spreadsheet, for a new database |
| `supabase/scripts/` | one-off SQL: a full snapshot, and finding duplicates to merge |
| `backup.mjs` | copies the `people` table to `backups/` |

### Deploying to new Cloudflare and Supabase accounts

The whole setup takes about half an hour. Do the steps in order: the keys from step 2 and the site
address from step 3 are used in later steps.

#### 1. Install the tools

- **Python 3** with openpyxl (`build.py` imports it even when it only builds the page):

  ```bash
  pip install openpyxl
  ```

- **Node.js 20 or newer.** It runs Cloudflare's `wrangler` CLI through `npx`, generates the keys and
  runs `backup.mjs`.
- Optional: **psql**, in case the Supabase SQL editor refuses the 600 KB `seed.sql` (see step 6).

Run every command below from the repository root.

#### 2. Generate the keys

The site needs three values of its own: a VAPID key pair, which signs the push messages, and a
random secret that Supabase uses to prove its calls to `/api/notify`. Generate all three:

```bash
node -e "crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign']).then(async k=>{const j=await crypto.subtle.exportKey('jwk',k.privateKey);const r=Buffer.from(await crypto.subtle.exportKey('raw',k.publicKey));console.log('VAPID_PUBLIC='+r.toString('base64url'));console.log('VAPID_PRIVATE_JWK='+JSON.stringify({kty:j.kty,crv:j.crv,x:j.x,y:j.y,d:j.d}));console.log('NOTIFY_SECRET='+require('crypto').randomBytes(32).toString('hex'))})"
```

Copy `.env.example` to `.env` and paste the three lines in. `.env` is git-ignored, so keep a copy of
it somewhere safe, such as a password manager. If you lose `VAPID_PRIVATE_JWK`, every editor has to
turn notifications on again.

#### 3. Create the Cloudflare Pages project

1. Sign up at [dash.cloudflare.com](https://dash.cloudflare.com) (the free plan is enough).
2. Sign wrangler in. It opens a browser window to approve access:

   ```bash
   npx wrangler login
   ```

3. Create the project:

   ```bash
   npx wrangler pages project create rodoslov --production-branch main
   ```

4. Put the address it prints into `.env`, with no trailing slash. Every account shares the
   `pages.dev` namespace, so if `rodoslov` is taken you get something like
   `https://rodoslov-4xk.pages.dev`:

   ```
   SITE_URL=https://rodoslov-4xk.pages.dev
   ```

   Supabase sends new suggestions to this address (step 5).

#### 4. Create the Supabase project

1. Sign up at [supabase.com](https://supabase.com) and create a new project. Choose a region near
   the family (for example Frankfurt) and save the database password it shows you.
   On the free plan, Supabase pauses a project that gets no traffic for a week; you can resume it
   from the dashboard.
2. In **Project Settings → API Keys**, copy the **publishable** key (older projects call it
   `anon`). In **Project Settings → Data API**, copy the project URL. Put both in `.env`:

   ```
   SUPABASE_URL=https://abcdefghijklmnop.supabase.co
   SUPABASE_KEY=sb_publishable_...
   ```

   Both values end up in the public page. **Never use the secret / `service_role` key here:** it
   bypasses all of the database's access rules.

#### 5. Create the database

Open **SQL Editor** in Supabase. Run each file below as its own query: open a new query, paste the
whole file, make sure nothing is highlighted, and click **Run**. If the editor warns about
destructive operations, confirm; the migrations only replace their own constraints and functions.

1. `supabase/migrations/20261018000000_init.sql`
2. `supabase/migrations/20261018020000_child_suggestions.sql`
3. `supabase/migrations/20261019000000_admin_create_delete.sql`
4. `supabase/migrations/20261019010000_root_suggestions.sql`
5. `supabase/migrations/20261020000000_merge_people.sql`
6. `supabase/migrations/20261020010000_merge_people_v2.sql`
7. `supabase/migrations/20261020020000_link_suggestions.sql`
8. `build/vault.sql`, which stores `SITE_URL` and `NOTIFY_SECRET` in Supabase's Vault, where the
   notification trigger reads them. Generate it from `.env` first:

   ```bash
   python build.py
   ```

   It's git-ignored because it contains the secret. Run it again whenever either value changes.
9. `supabase/migrations/20261022000000_push_notifications.sql`
10. `supabase/migrations/20261022000100_push_notifications_functions.sql`

The two notification files have to be separate queries: the editor's "table without RLS" check
cuts off function bodies that follow a `create table` in the same query.

#### 6. Load the people

**Starting fresh from the spreadsheet:** run `supabase/seed.sql` in the SQL editor. It already
includes the fixes in `build.py`, so you don't need `supabase/patch.sql` on a new database.

If the editor rejects the file as too large, load it with psql instead. Click **Connect** at the
top of the Supabase dashboard, copy the session pooler connection string, fill in your database
password, and run:

```bash
psql "postgresql://postgres.abcdefghijklmnop:PASSWORD@aws-0-eu-central-1.pooler.supabase.com:5432/postgres" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

**Moving an existing site, with the edits approved there:** point `.env` at the *old* project for a
moment, run `node backup.mjs`, then point `.env` back to the new project. Run the
`backups/people-<stamp>-restore.sql` it wrote in the new project's SQL editor, instead of
`seed.sql`. This copies the `people` table only; suggestions, editors and deleted people stay behind.

Check the result:

```sql
select count(*) from public.people;
```

#### 7. Add the editors

Visitors can't create accounts on the site. Each editor gets an account you create by hand:

1. **Authentication → Users → Add user → Create new user.** Enter their e-mail address and a
   password, and tick **Auto Confirm User**.
2. Give that address editor rights in the SQL editor:

   ```sql
   insert into public.admins (email) values ('editor@example.com');
   ```

   Editor rights come from this table only. An account that isn't listed here can sign in, but the
   site signs it straight back out.
3. Recommended: under **Authentication → Sign In / Providers**, turn off **Allow new users to sign
   up**, so nobody can create accounts through the API.
4. Under **Authentication → URL Configuration**, set **Site URL** to the site's address from step 3.

#### 8. Build and deploy

1. Give the Pages project the four secrets the notification function reads. Each command prompts for
   the value; paste it from `.env`. For `VAPID_PRIVATE_JWK`, paste the whole JSON on one line.

   ```bash
   npx wrangler pages secret put NOTIFY_SECRET --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put VAPID_PRIVATE_JWK --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put SUPABASE_URL --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put SUPABASE_KEY --project-name rodoslov
   ```

   A deployment only picks up the secrets that existed when it was made. If you change a secret
   later, deploy again.

2. Build the pages:

   ```bash
   python build.py
   ```

3. Deploy `site/`. Run this from the repository root, so wrangler also finds `functions/` and
   bundles the notification function:

   ```bash
   npx wrangler pages deploy site --project-name rodoslov --branch main
   ```

Use your own project name in place of `rodoslov` if you picked a different one.

#### 9. Check that it works

1. Open the site. The tree should load; on a phone you're sent to `telefon.html`.
2. Sign in as an editor. The review button appears.
3. In the review panel, turn on notifications and allow them in the browser. (On an iPhone, first add
   the site to the Home Screen and open it from there. iOS only allows notifications for sites
   opened that way.)
4. In a private window, without signing in, suggest a change to someone. The editor's device should
   get a notification within a few seconds, and the suggestion should be waiting in the review panel.

If no notification arrives:

- See what Supabase got back from `/api/notify`:

  ```sql
  select created, status_code, content, error_msg from net._http_response order by created desc limit 5;
  ```

  A `403` means the Vault secret and the Pages `NOTIFY_SECRET` differ. A `404` or a connection
  error means `SITE_URL` is wrong: fix it in `.env`, run `python build.py`, and run `build/vault.sql`
  again.
- Watch the function's log while you file another suggestion:

  ```bash
  npx wrangler pages deployment tail --project-name rodoslov
  ```

- No request at all means the trigger skipped it: no editor has notifications on yet,
  `build/vault.sql` hasn't been run, or you were signed in as an editor when you made the
  suggestion. Editors' own changes are never announced.

#### Optional extras

- **Custom domain:** in the Pages project, open **Custom domains** and add yours. Then set
  `SITE_URL` in `.env` to it, run `python build.py`, run `build/vault.sql` in the SQL editor, and
  change the Supabase Site URL to match.
- **Visitor statistics:** turn on Cloudflare Web Analytics in the Pages project's **Metrics** tab.
  `build.py` writes a real `<body>` element because the analytics script needs one.

### Day to day

- **Change the page:** edit `src/`, then run `python build.py` and the `wrangler pages deploy`
  command from step 8.
- **Preview locally:** after `python build.py`, serve `site/` with
  `python -m http.server 8765 --directory site`. The local page uses the real Supabase data.
  Notifications only work on `https` or `localhost`.
- **Change the database:** add a new file to `supabase/migrations/` and run it in the SQL editor.
- **Merge duplicated people:** follow `supabase/scripts/merge_duplicates.sql` one step at a time.
- **Back up:** `node backup.mjs` copies the `people` table to `backups/`, along with SQL to restore
  it. For everything else (suggestions, editors, deleted people), run
  `supabase/scripts/snapshot.sql` in the SQL editor. It keeps dated copies inside the database.
- **Fix the spreadsheet import:** edit the corrections at the top of `build.py`, then run
  `python build.py --patch` and run the `supabase/patch.sql` it writes. Edits already approved on
  the site are kept.

## Srpski

Sajt sa rodoslovom porodica iz Malog i Velikog Cvjetnića. Posetioci pregledaju stablo i predlažu
izmene, a urednici se prijavljuju i odobravaju ih.

### Kako je sve povezano

- **Supabase** čuva podatke (`people`, `suggestions`, `admins`, `push_subscriptions`), prijavu
  urednika (e-pošta i lozinka) i funkcije baze koje odobravaju, spajaju i brišu osobe. Zaštita na
  nivou redova (row-level security) dozvoljava javnom ključu samo da čita osobe i šalje predloge.
- **Cloudflare Pages** služi statične stranice koje `build.py` upisuje u `site/` i jednu Pages
  funkciju, `functions/api/notify.js` (na adresi `/api/notify`).
- **Obaveštenja.** Kada posetilac pošalje predlog, okidač (trigger) u bazi ga preko `pg_net` šalje
  na `/api/notify`, zajedno sa zajedničkom tajnom. Funkcija zatim šalje Web Push obaveštenje na svaki
  uređaj na kome je urednik uključio obaveštenja.

Stranica nema sopstveni server: `build.py` upisuje Supabase adresu i javni ključ u HTML, a
pregledač razgovara direktno sa Supabase-om.

| Putanja | Šta je |
| --- | --- |
| `build.py` | pravi `site/`; od `export.xlsx` (izvorne tabele, koja se ne čuva u gitu) pravi i `supabase/seed.sql` |
| `src/` | šabloni stranica (`template.html` za računar, `phone.html` za telefon), service worker, manifest, ikonice |
| `functions/api/notify.js`, `lib/webpush.js` | Pages funkcija koja šalje obaveštenja |
| `supabase/migrations/` | šema baze, redom kojim se pokreće |
| `supabase/seed.sql` | sve osobe iz tabele, za novu bazu |
| `supabase/scripts/` | jednokratni SQL: pun snimak baze i traženje duplikata za spajanje |
| `backup.mjs` | kopira tabelu `people` u `backups/` |

### Postavljanje na nove Cloudflare i Supabase naloge

Ceo postupak traje oko pola sata. Radite korake redom: ključevi iz koraka 2 i adresa sajta iz
koraka 3 koriste se u kasnijim koracima.

#### 1. Instalirajte alate

- **Python 3** sa paketom openpyxl (`build.py` ga učitava čak i kada samo pravi stranicu):

  ```bash
  pip install openpyxl
  ```

- **Node.js 20 ili noviji.** Preko `npx` pokreće Cloudflare-ov alat `wrangler`, pravi ključeve i
  pokreće `backup.mjs`.
- Po želji: **psql**, za slučaj da Supabase SQL editor odbije `seed.sql` od 600 KB (vidi korak 6).

Sve komande ispod pokrenite iz korena repozitorijuma.

#### 2. Napravite ključeve

Sajtu trebaju tri sopstvene vrednosti: VAPID par ključeva, kojim se potpisuju push poruke, i
nasumična tajna kojom Supabase dokazuje da pozivi na `/api/notify` stižu od njega. Napravite sve tri:

```bash
node -e "crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign']).then(async k=>{const j=await crypto.subtle.exportKey('jwk',k.privateKey);const r=Buffer.from(await crypto.subtle.exportKey('raw',k.publicKey));console.log('VAPID_PUBLIC='+r.toString('base64url'));console.log('VAPID_PRIVATE_JWK='+JSON.stringify({kty:j.kty,crv:j.crv,x:j.x,y:j.y,d:j.d}));console.log('NOTIFY_SECRET='+require('crypto').randomBytes(32).toString('hex'))})"
```

Kopirajte `.env.example` u `.env` i nalepite te tri linije. Git ne prati `.env`, pa njegovu kopiju
čuvajte na sigurnom mestu, na primer u menadžeru lozinki. Ako izgubite `VAPID_PRIVATE_JWK`, svaki
urednik mora ponovo da uključi obaveštenja.

#### 3. Napravite Cloudflare Pages projekat

1. Napravite nalog na [dash.cloudflare.com](https://dash.cloudflare.com) (besplatan plan je
   dovoljan).
2. Prijavite wrangler. Otvoriće se prozor pregledača u kome odobravate pristup:

   ```bash
   npx wrangler login
   ```

3. Napravite projekat:

   ```bash
   npx wrangler pages project create rodoslov --production-branch main
   ```

4. Adresu koju ispiše upišite u `.env`, bez kose crte na kraju. Svi nalozi dele imena na
   `pages.dev`, pa ako je `rodoslov` zauzet, dobićete nešto poput `https://rodoslov-4xk.pages.dev`:

   ```
   SITE_URL=https://rodoslov-4xk.pages.dev
   ```

   Supabase šalje nove predloge na ovu adresu (korak 5).

#### 4. Napravite Supabase projekat

1. Napravite nalog na [supabase.com](https://supabase.com) i novi projekat. Izaberite region blizu
   porodice (na primer Frankfurt) i sačuvajte lozinku baze koju vam prikaže.
   Na besplatnom planu Supabase pauzira projekat koji nedelju dana nema saobraćaja; možete ga ponovo
   pokrenuti iz kontrolne table.
2. U **Project Settings → API Keys** kopirajte **publishable** ključ (stariji projekti ga zovu
   `anon`). U **Project Settings → Data API** kopirajte adresu projekta. Upišite oba u `.env`:

   ```
   SUPABASE_URL=https://abcdefghijklmnop.supabase.co
   SUPABASE_KEY=sb_publishable_...
   ```

   Obe vrednosti završavaju u javnoj stranici. **Ovde nikada ne koristite secret / `service_role`
   ključ:** on zaobilazi sva pravila pristupa u bazi.

#### 5. Napravite bazu

Otvorite **SQL Editor** u Supabase-u. Svaki fajl ispod pokrenite kao poseban upit: otvorite novi
upit, nalepite ceo fajl, proverite da ništa nije označeno i kliknite **Run**. Ako editor upozori na
destruktivne operacije, potvrdite; migracije menjaju samo sopstvena ograničenja i funkcije.

1. `supabase/migrations/20261018000000_init.sql`
2. `supabase/migrations/20261018020000_child_suggestions.sql`
3. `supabase/migrations/20261019000000_admin_create_delete.sql`
4. `supabase/migrations/20261019010000_root_suggestions.sql`
5. `supabase/migrations/20261020000000_merge_people.sql`
6. `supabase/migrations/20261020010000_merge_people_v2.sql`
7. `supabase/migrations/20261020020000_link_suggestions.sql`
8. `build/vault.sql`, koji upisuje `SITE_URL` i `NOTIFY_SECRET` u Supabase Vault, odakle ih čita
   okidač za obaveštenja. Prvo ga napravite iz `.env`:

   ```bash
   python build.py
   ```

   Git ga ne prati jer sadrži tajnu. Pokrenite ga ponovo kad god se neka od te dve vrednosti
   promeni.
9. `supabase/migrations/20261022000000_push_notifications.sql`
10. `supabase/migrations/20261022000100_push_notifications_functions.sql`

Dva fajla za obaveštenja moraju biti posebni upiti: editorova provera „table without RLS" odseca
tela funkcija koje dolaze posle `create table` u istom upitu.

#### 6. Učitajte osobe

**Novi početak iz tabele:** pokrenite `supabase/seed.sql` u SQL editoru. On već sadrži ispravke iz
`build.py`, pa vam `supabase/patch.sql` na novoj bazi ne treba.

Ako editor odbije fajl kao prevelik, učitajte ga preko psql. Kliknite **Connect** na vrhu Supabase
kontrolne table, kopirajte vezu (connection string) za session pooler, upišite lozinku baze i
pokrenite:

```bash
psql "postgresql://postgres.abcdefghijklmnop:PASSWORD@aws-0-eu-central-1.pooler.supabase.com:5432/postgres" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

**Selidba postojećeg sajta, sa izmenama koje su tamo odobrene:** na trenutak usmerite `.env` na
*stari* projekat, pokrenite `node backup.mjs`, pa vratite `.env` na novi projekat. U SQL editoru
novog projekta pokrenite `backups/people-<stamp>-restore.sql` koji je skripta napravila, umesto
`seed.sql`. Ovo kopira samo tabelu `people`; predlozi, urednici i obrisane osobe ostaju u starom
projektu.

Proverite rezultat:

```sql
select count(*) from public.people;
```

#### 7. Dodajte urednike

Posetioci ne mogu da prave naloge na sajtu. Svakom uredniku nalog pravite ručno:

1. **Authentication → Users → Add user → Create new user.** Upišite adresu e-pošte i lozinku i
   štiklirajte **Auto Confirm User**.
2. Dajte toj adresi urednička prava u SQL editoru:

   ```sql
   insert into public.admins (email) values ('urednik@example.com');
   ```

   Urednička prava dolaze samo iz ove tabele. Nalog koji nije na spisku može da se prijavi, ali ga
   sajt odmah odjavi.
3. Preporučeno: u **Authentication → Sign In / Providers** isključite **Allow new users to sign
   up**, da niko ne bi mogao da pravi naloge preko API-ja.
4. U **Authentication → URL Configuration** postavite **Site URL** na adresu sajta iz koraka 3.

#### 8. Napravite i objavite sajt

1. Dajte Pages projektu četiri tajne koje funkcija za obaveštenja čita. Svaka komanda traži
   vrednost; nalepite je iz `.env`. Za `VAPID_PRIVATE_JWK` nalepite ceo JSON u jednom redu.

   ```bash
   npx wrangler pages secret put NOTIFY_SECRET --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put VAPID_PRIVATE_JWK --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put SUPABASE_URL --project-name rodoslov
   ```

   ```bash
   npx wrangler pages secret put SUPABASE_KEY --project-name rodoslov
   ```

   Objava (deployment) vidi samo tajne koje su postojale kada je napravljena. Ako kasnije promenite
   neku tajnu, objavite sajt ponovo.

2. Napravite stranice:

   ```bash
   python build.py
   ```

3. Objavite `site/`. Pokrenite ovo iz korena repozitorijuma, da bi wrangler našao i `functions/` i
   spakovao funkciju za obaveštenja:

   ```bash
   npx wrangler pages deploy site --project-name rodoslov --branch main
   ```

Ako ste izabrali drugo ime projekta, koristite ga umesto `rodoslov`.

#### 9. Proverite da sve radi

1. Otvorite sajt. Stablo treba da se učita; telefon vas prebacuje na `telefon.html`.
2. Prijavite se kao urednik. Pojavljuje se dugme za pregled predloga.
3. U panelu za pregled uključite obaveštenja i dozvolite ih u pregledaču. (Na iPhone-u prvo dodajte
   sajt na početni ekran (Home Screen) i otvorite ga odatle. iOS dozvoljava obaveštenja samo
   sajtovima otvorenim na taj način.)
4. U privatnom prozoru, bez prijave, predložite izmenu za nekoga. Uređaj urednika treba da dobije
   obaveštenje za nekoliko sekundi, a predlog treba da čeka u panelu za pregled.

Ako obaveštenje ne stigne:

- Pogledajte šta je Supabase dobio od `/api/notify`:

  ```sql
  select created, status_code, content, error_msg from net._http_response order by created desc limit 5;
  ```

  `403` znači da se tajna u Vault-u i `NOTIFY_SECRET` u Pages projektu razlikuju. `404` ili greška
  pri povezivanju znači da `SITE_URL` nije dobar: ispravite ga u `.env`, pokrenite `python build.py`
  i ponovo pokrenite `build/vault.sql`.
- Pratite dnevnik funkcije dok šaljete još jedan predlog:

  ```bash
  npx wrangler pages deployment tail --project-name rodoslov
  ```

- Ako zahteva uopšte nema, okidač ga je preskočio: nijedan urednik još nije uključio obaveštenja,
  `build/vault.sql` nije pokrenut, ili ste predlog poslali prijavljeni kao urednik. Izmene samih
  urednika se nikad ne najavljuju.

#### Dodatno, po želji

- **Sopstveni domen:** u Pages projektu otvorite **Custom domains** i dodajte svoj. Zatim u `.env`
  postavite `SITE_URL` na njega, pokrenite `python build.py`, pokrenite `build/vault.sql` u SQL
  editoru i promenite Site URL u Supabase-u da odgovara.
- **Statistika poseta:** uključite Cloudflare Web Analytics na kartici **Metrics** u Pages
  projektu. `build.py` piše pravi `<body>` element jer ga skripta za analitiku zahteva.

### Svakodnevni rad

- **Izmena stranice:** izmenite `src/`, zatim pokrenite `python build.py` i komandu
  `wrangler pages deploy` iz koraka 8.
- **Lokalni pregled:** posle `python build.py` poslužite `site/` komandom
  `python -m http.server 8765 --directory site`. Lokalna stranica koristi prave podatke iz
  Supabase-a. Obaveštenja rade samo preko `https` ili na `localhost`.
- **Izmena baze:** dodajte novi fajl u `supabase/migrations/` i pokrenite ga u SQL editoru.
- **Spajanje duplikata:** pratite `supabase/scripts/merge_duplicates.sql` korak po korak.
- **Rezervna kopija:** `node backup.mjs` kopira tabelu `people` u `backups/`, zajedno sa SQL-om za
  vraćanje. Za sve ostalo (predlozi, urednici, obrisane osobe) pokrenite
  `supabase/scripts/snapshot.sql` u SQL editoru. On čuva datirane kopije u samoj bazi.
- **Ispravke uvoza iz tabele:** izmenite ispravke na vrhu `build.py`, zatim pokrenite
  `python build.py --patch` i pokrenite `supabase/patch.sql` koji napravi. Izmene koje su već
  odobrene na sajtu ostaju sačuvane.
