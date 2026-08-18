-- Counter Acceptance certification and hire date were UI fields
-- (state.staff[].counterCert / .hireDate) that were never given a column —
-- the staff-manager form's "✅ Counter Acceptance certified" toggle and
-- hire-date input silently never made it to the database. Adding them here
-- so both the manual form and the upcoming Excel import have somewhere real
-- to write these values.

alter table staff
  add column counter_cert boolean not null default false,
  add column hire_date date;
