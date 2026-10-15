-- Adds a real 3-tier hierarchy to the previously-flat supervisors table:
-- PSM (top) -> APSM -> SL (the existing "supervisor" level staff report
-- to today). tier is informational/display; reports_to_id is the actual
-- edge the org chart walks. Self-referencing FK with on delete set null
-- so removing a PSM/APSM doesn't cascade-delete their reports — it just
-- orphans them back to the top of the chart, same as "no supervisor"
-- already works for staff.
alter table supervisors
  add column tier text not null default 'sl' check (tier in ('psm','apsm','sl')),
  add column reports_to_id uuid references supervisors(id) on delete set null;

-- Seed from the user's answer: Thomasina is PSM, Jazmine is APSM
-- (reporting to Thomasina), everyone else already in the table defaults
-- to SL (reporting to Jazmine, the only APSM today).
update supervisors set tier = 'psm'
  where id = '401af4d5-d876-413c-bb6e-cedbd0cba149'; -- Thomasina

update supervisors set tier = 'apsm', reports_to_id = '401af4d5-d876-413c-bb6e-cedbd0cba149'
  where id = 'f8fd3035-baa8-4676-a555-de2b829d6691'; -- Jazmine

update supervisors set tier = 'sl', reports_to_id = 'f8fd3035-baa8-4676-a555-de2b829d6691'
  where id not in ('401af4d5-d876-413c-bb6e-cedbd0cba149', 'f8fd3035-baa8-4676-a555-de2b829d6691');
