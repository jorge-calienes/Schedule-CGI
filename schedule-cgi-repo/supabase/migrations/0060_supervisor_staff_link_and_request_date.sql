-- A supervisor also gets scheduled on the board like any other staff
-- member -- e.g. "Austin" (an sl-tier supervisor) also has a staff row
-- "Austin Nikirk" so he gets an area assignment, a TDIS, a profile, etc.
-- When that staff row takes time off, it was being counted toward the
-- leave-policy cap the same as everyone else's -- but that cap exists to
-- protect line-staff coverage, not supervisor availability, so a
-- supervisor's own day off shouldn't eat into it. There was no link
-- anywhere between a supervisors row and the staff row it also has, so
-- there was no way to tell them apart in the capacity math. This nullable
-- link makes that possible; matching existing rows by name is a one-off
-- data fix applied separately (not DDL, so not in this file).
alter table supervisors add column if not exists staff_id uuid references staff(id);

-- Lets a supervisor record when a time-off entry was actually asked for,
-- separate from created_at (when it was typed into the system -- which can
-- be well after the real ask, e.g. a backlog of paper/verbal requests
-- entered in one sitting). Without this there's no way to later
-- reconstruct who asked first for a contested day that was added directly
-- here rather than through the self-service form (which already has its
-- own "asked first" signal: leave_requests.created_at).
alter table time_off add column if not exists requested_at date;

-- submit_leave_request()'s capacity check now excludes staff linked from a
-- supervisors row (see above) from both sides of the day's used-slots
-- count, so a supervisor's own time off never counts against the cap that
-- blocks regular staff from submitting.
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
      (select count(*) from time_off t where d::date between t.start_date and t.end_date
         and t.staff_id not in (select staff_id from supervisors where staff_id is not null))
      +
      (select count(*) from leave_requests lr
         where lr.status in ('pending','approved') and d::date between lr.start_date and lr.end_date
           and lr.staff_id not in (select staff_id from supervisors where staff_id is not null))
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

-- check_my_requests()'s capacity_used/on_bench read gets the same
-- supervisor exclusion, so a staff member's own-status check always
-- agrees with what submit_leave_request() actually enforced.
create or replace function check_my_requests(
  p_staff_id uuid,
  p_tdis text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff;
  v_rule_type text;
  v_max_percent numeric;
  v_max_count integer;
  v_active_count integer;
  v_cap integer;
begin
  select * into v_staff from staff where id = p_staff_id and active = true;
  if v_staff is null then
    raise exception 'staff_not_found' using errcode = 'P0001';
  end if;
  if v_staff.tdis_number is null or btrim(upper(v_staff.tdis_number)) <> btrim(upper(p_tdis)) then
    raise exception 'tdis_mismatch' using errcode = 'P0001';
  end if;

  select rule_type, max_percent, max_count into v_rule_type, v_max_percent, v_max_count from leave_policy where id = true;
  select count(*) into v_active_count from staff where active = true;
  if v_rule_type = 'count' then
    v_cap := greatest(coalesce(v_max_count, 1), 1);
  else
    v_cap := ceil(coalesce(v_max_percent, 15) * v_active_count / 100.0);
  end if;

  return jsonb_build_object(
    'leave_requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', lr.id,
        'leave_type', lr.leave_type,
        'start_date', lr.start_date,
        'end_date', lr.end_date,
        'status', lr.status,
        'decided_at', lr.decided_at,
        'decision_note', lr.decision_note,
        'created_at', lr.created_at,
        'capacity_used', (select count(*) from time_off t where lr.start_date between t.start_date and t.end_date
           and t.staff_id not in (select staff_id from supervisors where staff_id is not null)),
        'capacity_cap', v_cap,
        'on_bench', lr.status = 'pending' and (
          (select count(*) from time_off t where lr.start_date between t.start_date and t.end_date
             and t.staff_id not in (select staff_id from supervisors where staff_id is not null))
          +
          (select count(*) from leave_requests other
             where other.status = 'pending' and other.start_date = lr.start_date and other.created_at <= lr.created_at
               and other.staff_id not in (select staff_id from supervisors where staff_id is not null))
        ) > v_cap
      ) order by lr.created_at desc), '[]'::jsonb)
      from (
        select * from leave_requests where staff_id = p_staff_id order by created_at desc limit 10
      ) lr
    ),
    'same_day_requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', sd.id,
        'request_type', sd.request_type,
        'request_date', sd.request_date,
        'status', sd.status,
        'decided_at', sd.decided_at,
        'actual_time', sd.actual_time,
        'hours_impact', sd.hours_impact,
        'created_at', sd.created_at
      ) order by sd.created_at desc), '[]'::jsonb)
      from (
        select * from same_day_requests where staff_id = p_staff_id order by created_at desc limit 10
      ) sd
    )
  );
end;
$$;

-- public_board_snapshot() now also hands back each supervisor's linked
-- staff_id, plus a flat supervisor_staff_ids list, so the client-side
-- capacity math (pbCapacityForDate/pbMonthCardHtml in index.html, and the
-- authenticated app's own capacity view which builds an equivalent
-- snapshot) can exclude those staff ids from the "used" count the same way
-- submit_leave_request()/check_my_requests() now do server-side.
create or replace function public.public_board_snapshot()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
        'id', sv.id, 'name', sv.name, 'color', sv.color, 'staff_id', sv.staff_id
      )), '[]'::jsonb)
      from supervisors sv
    ),
    'supervisor_staff_ids', (
      select coalesce(jsonb_agg(sv.staff_id), '[]'::jsonb)
      from supervisors sv
      where sv.staff_id is not null
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
$function$;
