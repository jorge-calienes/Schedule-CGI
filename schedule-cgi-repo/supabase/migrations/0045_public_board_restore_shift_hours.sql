-- Correction to 0044: "no time" was only meant for the By-supervisor
-- status view, not the area view too. Restore shift_hours_label — the
-- area-view chip (renderPublicChip) shows it again; the supervisor-view
-- status chip (renderPublicStatusChip) never selects it in the first
-- place, so no further client change needed there.
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
    'generated_at', now()
  );
$$;

revoke all on function public_board_snapshot() from public;
grant execute on function public_board_snapshot() to anon;
