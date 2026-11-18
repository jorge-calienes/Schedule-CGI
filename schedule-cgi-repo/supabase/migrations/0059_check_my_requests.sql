-- Lets someone on the public board check the status of their own
-- self-service requests -- until now, once a leave request or same-day
-- notice was sent, there was no way to come back and see whether it had
-- been approved, denied, or was still waiting, short of asking a
-- supervisor directly. Same TDIS-verification pattern as
-- submit_leave_request()/submit_same_day_request(): a SECURITY DEFINER
-- function grantable to anon that checks the submitted TDIS against the
-- chosen staff record server-side, so nobody can look up someone else's
-- requests by guessing a staff_id.
--
-- For each still-pending leave request, also reports whether it currently
-- fits in an open slot or is "on the bench" -- the exact same
-- rank-in-submission-order-vs-remaining-capacity read the supervisor's
-- pending-queue view shows them (renderPendingLeaveRequestsModal in
-- index.html) -- so a requester isn't left guessing whether their day is
-- at risk of needing an overflow override.
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

  -- Same cap formula submit_leave_request() uses, computed once here
  -- against the current policy (same "as of now" approximation the
  -- supervisor's own queue view already makes).
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
        'capacity_used', (select count(*) from time_off t where lr.start_date between t.start_date and t.end_date),
        'capacity_cap', v_cap,
        'on_bench', lr.status = 'pending' and (
          (select count(*) from time_off t where lr.start_date between t.start_date and t.end_date)
          +
          (select count(*) from leave_requests other
             where other.status = 'pending' and other.start_date = lr.start_date and other.created_at <= lr.created_at)
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

revoke all on function check_my_requests(uuid, text) from public;
grant execute on function check_my_requests(uuid, text) to anon, authenticated;
