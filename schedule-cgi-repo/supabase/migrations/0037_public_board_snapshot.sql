-- Public, unauthenticated "just the board" read path.
--
-- Every existing read policy in this schema gates on `auth.uid() is not
-- null` — i.e. any signed-in account, admin through team lead, can read
-- the full staff table (tdis_number, hire_date, needs_accommodations,
-- break_times_label, etc.). There is deliberately no anonymous access at
-- all today.
--
-- A shareable "view only" board link needs real anonymous (anon role,
-- zero sign-in) access, but must never expose those personal-info
-- columns, and must never be a path to any other table. Plain RLS can't
-- restrict by column — only by row — so this ships as a single
-- SECURITY DEFINER function that explicitly selects just the safe
-- columns and returns them as one JSON blob. The anon role is granted
-- EXECUTE on this function only; it is never granted SELECT on staff,
-- assignments, callouts, or anything else, so there is no way to query
-- those tables directly as anon and see more than this function chooses
-- to expose. This mirrors the existing current_account()/is_manager()
-- pattern above, which already uses SECURITY DEFINER to read `accounts`
-- past its own RLS.
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
    -- name + team-lead flag only — no tdis_number, hire_date,
    -- needs_accommodations, break_times_label, shift_hours_label, tags,
    -- supervisor_id, is_subcontractor, counter_cert, or language certs.
    'staff', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'is_team_lead', s.is_team_lead,
        'department_id', s.department_id
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
