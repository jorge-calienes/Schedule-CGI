-- Follow-up to 0037/0038: the public board should show the same
-- rotation-relevant status flags the real board shows — late arrival,
-- left early, out (manual callout or scheduled time off) — but, per
-- "just for the rotation", only the flag itself, never the reason/note
-- text behind it (attendance_events.note, time_off.label, callouts.reason
-- all stay out).
--
-- 'out' now also independently checks time_off directly, instead of
-- relying only on the client-side-triggered 'scheduled' callout row
-- (_applyTodayTimeOff() in index.html writes that row, but only once some
-- signed-in supervisor/admin has loaded the app that day) — the public
-- board shouldn't be stale just because no one with an account has opened
-- the real app yet today.
create or replace function public_board_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'departments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'name', d.name, 'sort_order', d.sort_order
      ) order by d.sort_order), '[]'::jsonb)
      from departments d
    ),
    'areas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'name', a.name, 'department_id', a.department_id,
        'color', a.color, 'capacity', a.capacity, 'sort_order', a.sort_order
      ) order by a.sort_order), '[]'::jsonb)
      from areas a
      where a.archived = false
    ),
    'supervisors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', sv.id, 'name', sv.name, 'color', sv.color
      )), '[]'::jsonb)
      from supervisors sv
    ),
    'staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'is_team_lead', s.is_team_lead,
        'department_id', s.department_id,
        'tdis_number', s.tdis_number,
        'shift_hours_label', s.shift_hours_label,
        'break_times_label', s.break_times_label,
        'supervisor_id', s.supervisor_id
      )), '[]'::jsonb)
      from staff s
      where s.active = true
    ),
    'assignments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'staff_id', asg.staff_id, 'area_id', asg.area_id
      )), '[]'::jsonb)
      from assignments asg
      join staff s on s.id = asg.staff_id and s.active = true
    ),
    -- out today: manual callout OR a time_off record covering today,
    -- whichever already exists — no reason text from either source.
    'callout_staff_ids', (
      select coalesce(jsonb_agg(distinct staff_id), '[]'::jsonb)
      from (
        select c.staff_id from callouts c
          join staff s on s.id = c.staff_id and s.active = true
        union
        select t.staff_id from time_off t
          join staff s on s.id = t.staff_id and s.active = true
          where current_date between t.start_date and t.end_date
      ) out_today
    ),
    'late_staff_ids', (
      select coalesce(jsonb_agg(distinct e.staff_id), '[]'::jsonb)
      from attendance_events e
        join staff s on s.id = e.staff_id and s.active = true
      where e.event_type = 'late_arrival' and e.event_date = current_date
    ),
    'left_early_staff_ids', (
      select coalesce(jsonb_agg(distinct e.staff_id), '[]'::jsonb)
      from attendance_events e
        join staff s on s.id = e.staff_id and s.active = true
      where e.event_type = 'left_early' and e.event_date = current_date
    ),
    'generated_at', now()
  );
$$;

revoke all on function public_board_snapshot() from public;
grant execute on function public_board_snapshot() to anon;
