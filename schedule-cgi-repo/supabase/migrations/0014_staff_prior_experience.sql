-- Rotation history (state.history) only goes back as far as this app has
-- been recording "Rotate Now" actions — someone who genuinely worked an
-- area before that (a prior job, or before the system started tracking)
-- has no way to show up in timesWorkedArea()/staffExperienceBreakdown().
-- This is a lightweight manual checklist an admin/supervisor can mark on
-- a staff member's profile: "they've worked this area before", with an
-- optional note. No dates — just a flag per (staff, area), same RLS
-- split as the other manager-only catalogs.

create table staff_prior_experience (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references staff(id) on delete cascade,
  area_id    uuid not null references areas(id) on delete cascade,
  note       text,
  added_by   uuid references accounts(id),
  created_at timestamptz not null default now(),
  unique (staff_id, area_id)
);

alter table staff_prior_experience enable row level security;
create policy staff_prior_experience_select on staff_prior_experience for select using (auth.uid() is not null);
create policy staff_prior_experience_write  on staff_prior_experience for all using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table staff_prior_experience;
