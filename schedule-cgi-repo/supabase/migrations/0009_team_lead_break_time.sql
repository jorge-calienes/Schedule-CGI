-- Team leads get a narrow write: they may change a staff member's lunch/
-- break time (and only that column) for staff currently assigned to the
-- team lead's own area — everything else on `staff`, including shift
-- hours, stays admin/supervisor-only via the existing is_manager()-gated
-- staff_write policy. Mirrors the eval_insert policy's "currently assigned
-- to my area" scoping (see 0001_init.sql) rather than home_area_id, since
-- what a team lead should be able to touch is who's actually under them
-- on the live board right now, not their nominal home area.
--
-- RLS alone can pick which ROWS a team lead may update, but not which
-- COLUMNS within an allowed row — a plain permissive policy would let a
-- team lead's client send any column in the same PATCH. The trigger below
-- closes that gap: for anyone who isn't a manager, it rejects an update
-- that changes anything besides break_times_label.

create policy staff_write_team_lead_break_time on staff for update
  using (
    exists (
      select 1 from accounts a
      join assignments asg on asg.area_id = a.assigned_area_id
      where a.user_id = auth.uid()
        and a.role = 'team_lead'
        and asg.staff_id = staff.id
    )
  )
  with check (
    exists (
      select 1 from accounts a
      join assignments asg on asg.area_id = a.assigned_area_id
      where a.user_id = auth.uid()
        and a.role = 'team_lead'
        and asg.staff_id = staff.id
    )
  );

create or replace function enforce_team_lead_staff_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if is_manager() then
    return new;
  end if;

  if new.name is distinct from old.name
     or new.tdis_number is distinct from old.tdis_number
     or new.department_id is distinct from old.department_id
     or new.home_area_id is distinct from old.home_area_id
     or new.shift_id is distinct from old.shift_id
     or new.is_team_lead is distinct from old.is_team_lead
     or new.is_subcontractor is distinct from old.is_subcontractor
     or new.needs_accommodations is distinct from old.needs_accommodations
     or new.tags is distinct from old.tags
     or new.shift_hours_label is distinct from old.shift_hours_label
     or new.counter_cert is distinct from old.counter_cert
     or new.hire_date is distinct from old.hire_date
     or new.supervisor_id is distinct from old.supervisor_id
     or new.flow_id is distinct from old.flow_id
     or new.flow_enrolled is distinct from old.flow_enrolled
     or new.active is distinct from old.active
  then
    raise exception 'Team leads can only update lunch/break time';
  end if;

  return new;
end;
$$;

drop trigger if exists staff_team_lead_column_guard on staff;
create trigger staff_team_lead_column_guard
  before update on staff
  for each row execute function enforce_team_lead_staff_columns();

-- This is a trigger helper, not something meant to be called directly as an
-- RPC (PostgREST auto-exposes every public-schema function by default).
-- Calling it outside trigger context would already fail — NEW/OLD aren't
-- bound — but revoke execute anyway to keep it off the API surface.
revoke execute on function enforce_team_lead_staff_columns() from public, anon, authenticated;
