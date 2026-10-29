-- Fixes a privacy regression from 0049: public_board_snapshot()'s
-- leave_calendar used coalesce(t.label, 'Time off') for the time_off side,
-- which sends time_off.label straight to the public board — exactly the
-- free-text reason field 0039 established must never be public ("just the
-- flag itself, never the reason/note text behind it"). It also sent
-- upper(lr.leave_type), exposing PTO vs Sick, which goes further than what
-- was agreed for the public board: show only that someone is off, late, or
-- left early — never why or what kind. Both sides of the union now return
-- a fixed generic label; status (pending/approved) is kept since that's
-- useful "fewer slots" context, not a reason.
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
        'color', a.color, 'capacity', a.capacity, 'sort_order', a.sort_order,
        'fixed', a.fixed
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
    'callout_staff_ids', (
      select coalesce(jsonb_agg(distinct staff_id), '[]'::jsonb)
      from (
        select c.staff_id from callouts c
          join staff s on s.id = c.staff_id and s.active = true
          where c.marked_at::date = current_date
        union
        select t.staff_id from time_off t
          join staff s on s.id = t.staff_id and s.active = true
          where current_date between t.start_date and t.end_date
      ) out_today
    ),
    'scheduled_off_staff_ids', (
      select coalesce(jsonb_agg(distinct t.staff_id), '[]'::jsonb)
      from time_off t
        join staff s on s.id = t.staff_id and s.active = true
      where current_date between t.start_date and t.end_date
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
    'coverage_moves', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'staff_id', cv.staff_id, 'return_to_area_id', cv.return_to_area_id
      )), '[]'::jsonb)
      from coverage_assignments cv
        join staff s on s.id = cv.staff_id and s.active = true
    ),
    'temp_moves', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'staff_id', tm.staff_id, 'return_to_area_id', tm.return_to_area_id, 'scope', tm.scope
      )), '[]'::jsonb)
      from temp_moves tm
        join staff s on s.id = tm.staff_id and s.active = true
    ),
    'active_staff_count', (select count(*) from staff where active = true),
    'leave_policy', (select jsonb_build_object('max_percent', max_percent) from leave_policy where id = true),
    'company_holidays', (
      select coalesce(jsonb_agg(jsonb_build_object('date', h.holiday_date, 'label', h.label) order by h.holiday_date), '[]'::jsonb)
      from company_holidays h
      where h.holiday_date between current_date - interval '7 days' and current_date + interval '180 days'
    ),
    'leave_calendar', (
      select coalesce(jsonb_agg(row), '[]'::jsonb) from (
        select jsonb_build_object(
          'staff_id', t.staff_id, 'name', s.name, 'start_date', t.start_date, 'end_date', t.end_date,
          'type', 'Scheduled off', 'status', 'approved'
        ) as row
        from time_off t join staff s on s.id = t.staff_id and s.active = true
        where t.end_date >= current_date - interval '7 days' and t.start_date <= current_date + interval '180 days'
        union all
        select jsonb_build_object(
          'staff_id', lr.staff_id, 'name', s.name, 'start_date', lr.start_date, 'end_date', lr.end_date,
          'type', 'Scheduled off', 'status', lr.status
        ) as row
        from leave_requests lr join staff s on s.id = lr.staff_id and s.active = true
        where lr.status in ('pending','approved')
          and lr.end_date >= current_date - interval '7 days' and lr.start_date <= current_date + interval '180 days'
      ) combined
    ),
    'generated_at', now()
  );
$$;

revoke all on function public_board_snapshot() from public;
grant execute on function public_board_snapshot() to anon;
