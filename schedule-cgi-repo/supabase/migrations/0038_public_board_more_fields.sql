-- Follow-up to 0037: the user clarified "personal info" to keep out of the
-- public board means profile-level detail (hire date, accommodations
-- flag, language certs, attendance/Late status, AGS/subcontractor flag,
-- counter cert) and write access — not the operational info already
-- visible on every board card today (TDIS tag, shift/break times, which
-- supervisor someone reports to). Those three are now included; the
-- previously-excluded fields stay excluded.
--
-- Same SECURITY DEFINER / anon-execute-only shape as 0037 — see that
-- migration's comment for why this can't just be an RLS policy tweak.
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
    -- name, team-lead flag, TDIS number, shift/break times, and which
    -- supervisor they report to — everything already shown on an
    -- ordinary board card. Still never: hire_date, needs_accommodations,
    -- tags, is_subcontractor, counter_cert, language certs, or anything
    -- from a non-board table (evaluations, attendance_events, time_off).
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
    -- who's out right now, no reason text (that stays manager-only).
    'callout_staff_ids', (
      select coalesce(jsonb_agg(c.staff_id), '[]'::jsonb)
      from callouts c
      join staff s on s.id = c.staff_id and s.active = true
    ),
    'generated_at', now()
  );
$$;

revoke all on function public_board_snapshot() from public;
grant execute on function public_board_snapshot() to anon;
