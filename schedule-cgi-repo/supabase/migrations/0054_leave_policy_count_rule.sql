-- The capacity rule was percentage-only. Adds a 'count' mode -- a flat
-- number of people, not a share of the roster -- as an alternative to
-- 'percent'. Both max_percent and the new max_count stay stored at all
-- times (not cleared when the other mode is active), so flipping the
-- toggle in the Leave Policy screen doesn't lose whichever value isn't
-- currently in use.
alter table leave_policy
  add column rule_type text not null default 'percent' check (rule_type in ('percent','count')),
  add column max_count integer check (max_count is null or max_count > 0);

-- submit_leave_request()'s capacity check now branches on rule_type
-- instead of always computing a percent-of-roster cap.
create or replace function submit_leave_request(
  p_staff_id uuid,
  p_tdis text,
  p_leave_type text,
  p_start_date date,
  p_end_date date,
  p_hours_requested numeric,
  p_pto_balance numeric,
  p_sick_balance numeric,
  p_remarks text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff;
  v_cap integer;
  v_rule_type text;
  v_max_percent numeric;
  v_max_count integer;
  v_active_count integer;
  v_blocked_date date;
  v_row leave_requests;
begin
  select * into v_staff from staff where id = p_staff_id and active = true;
  if v_staff is null then
    raise exception 'staff_not_found' using errcode = 'P0001';
  end if;
  if v_staff.tdis_number is null or btrim(upper(v_staff.tdis_number)) <> btrim(upper(p_tdis)) then
    raise exception 'tdis_mismatch' using errcode = 'P0001';
  end if;
  if p_leave_type not in ('pto','sick') then
    raise exception 'invalid_leave_type' using errcode = 'P0001';
  end if;
  if p_end_date < p_start_date then
    raise exception 'invalid_date_range' using errcode = 'P0001';
  end if;

  select rule_type, max_percent, max_count into v_rule_type, v_max_percent, v_max_count from leave_policy where id = true;
  select count(*) into v_active_count from staff where active = true;
  if v_rule_type = 'count' then
    v_cap := greatest(coalesce(v_max_count, 1), 1);
  else
    v_cap := ceil(coalesce(v_max_percent, 15) * v_active_count / 100.0);
  end if;

  select d::date into v_blocked_date
  from generate_series(p_start_date, p_end_date, interval '1 day') d
  where extract(isodow from d) < 6
    and d::date not in (select holiday_date from company_holidays)
    and (
      (select count(*) from time_off t where d::date between t.start_date and t.end_date)
      +
      (select count(*) from leave_requests lr
         where lr.status in ('pending','approved') and d::date between lr.start_date and lr.end_date)
    ) >= v_cap
  order by d
  limit 1;

  if v_blocked_date is not null then
    raise exception 'capacity_full:%', v_blocked_date using errcode = 'P0001';
  end if;

  insert into leave_requests (
    staff_id, leave_type, start_date, end_date, hours_requested, pto_balance, sick_balance, remarks
  ) values (
    p_staff_id, p_leave_type, p_start_date, p_end_date, p_hours_requested, p_pto_balance, p_sick_balance, p_remarks
  )
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- public_board_snapshot()'s leave_policy field now also hands back
-- rule_type/max_count so the public board's client-side capacity math
-- (pbCapacityForDate in index.html, mirroring this same branch) agrees
-- with what the server will actually enforce.
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
    'leave_policy', (select jsonb_build_object('max_percent', max_percent, 'rule_type', rule_type, 'max_count', max_count) from leave_policy where id = true),
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
