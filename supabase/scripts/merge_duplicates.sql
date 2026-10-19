-- Merging duplicated people. Needs supabase/migrations/20261020000000_merge_people.sql to have run once.
-- Run one step at a time in the Supabase SQL editor (select the lines, then Run).

-- 1. Possible duplicates: same first name, surname and year, and either both line founders or children of
--    the same parent. "keep" is the older record (lower id).
select a.id as keep, b.id as drop, a.ime, a.prezime, a.rodjen,
       coalesce((select ime || ' ' || coalesce(rodjen::text, '') from people where id = a.roditelj_id), 'začetnik loze') as roditelj,
       (select count(*) from people where roditelj_id = a.id) as deca_keep,
       (select count(*) from people where roditelj_id = b.id) as deca_drop
from people a
join people b on a.id < b.id
  and lower(btrim(a.ime)) = lower(btrim(b.ime))
  and a.prezime is not distinct from b.prezime
  and a.rodjen = b.rodjen
  and a.roditelj_id is not distinct from b.roditelj_id
order by a.prezime, a.ime, a.rodjen;

-- 2. Risto Rodić (1840), twice as a line founder: #6334 (sons Rade and Nikola) and #6350 (Rade again, with
--    Ilija, Mihailo and second copies of Dragan, Stevo, Radenko and Gordana). Dry run: lists every step, saves nothing.
select * from merge_people(6334, 6350);

-- 3. When the list from step 2 looks right, do it:
-- select * from merge_people(6334, 6350, dry_run => false);

-- 4. Optional, after step 3: #6350 carried a visitor's report of exactly this error ("Ima greška, dva puta ste ga
--    stavili…"); the merge copies it onto #6334. Clear it if it is no longer needed:
-- update people set napomena = null, updated_at = now() where id = 6334 and napomena like 'Ima greška, dva puta ste ga stavili%';

-- 5. Milutin Pilipović (1932, page 516) and his wife Đuka Pilipović (1932, page 520) come from two Pilipović lines,
--    and the book lists their children under both: Milan, Milka, Dušanka and Kosovka. Milutin's copies are the
--    ones the family has filled in (spouses, grandchildren), so Đuka's four copies merge into them, pair by pair.
--    Milan (1954 / 1958) and Kosovka (1958 / 1960) differ in year: page 516's stays, the other goes into the note.
--    Dry run, all four at once:
select * from merge_people(5503, 4966)        -- Milan
union all select * from merge_people(5504, 4965)   -- Milka
union all select * from merge_people(5505, 4967)   -- Dušanka
union all select * from merge_people(5506, 4968);  -- Kosovka

-- 6. When step 5 looks right, do it, and link Đuka to Milutin as spouses ("Brak u stablu" on both):
-- select * from merge_people(5503, 4966, dry_run => false)
-- union all select * from merge_people(5504, 4965, dry_run => false)
-- union all select * from merge_people(5505, 4967, dry_run => false)
-- union all select * from merge_people(5506, 4968, dry_run => false);
-- update people set brak_id = 5502, updated_at = now() where id = 4964;

-- Undo, if ever needed: every merged-away record is in deleted_people (see deleted_at), e.g.
-- select id, ime, prezime, rodjen, roditelj_id, deleted_at from deleted_people order by deleted_at desc;
