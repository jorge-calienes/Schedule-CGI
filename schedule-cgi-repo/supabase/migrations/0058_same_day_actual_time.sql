-- Lets a same-day late-arrival/leaving-early request carry the actual time
-- someone will arrive or leave, plus a client-computed estimate of how many
-- hours that represents against PTO/Sick -- so the requester sees the
-- number up front, and a supervisor acknowledging the notice doesn't have
-- to do the math themselves against the person's scheduled shift.
--
-- Both columns are optional and purely informational (same spirit as
-- pto_balance/sick_balance on this table already): the estimate is computed
-- client-side from the staff member's free-typed shift_hours_label, which
-- isn't always parseable, so a request with neither set just means the
-- estimate couldn't be shown.
alter table same_day_requests add column actual_time text;
alter table same_day_requests add column hours_impact numeric;

-- Carried onto the attendance_events row when a notice is acknowledged
-- (reviewSameDayRequest -> markAttendanceEvent), so the same number is
-- still there later when reconciling attendance/timesheets, without having
-- to look the original request back up.
alter table attendance_events add column actual_time text;
alter table attendance_events add column hours_impact numeric;

-- CREATE OR REPLACE can add new parameters to an existing function as long
-- as they're appended with defaults -- the existing anon/authenticated
-- grants on this signature still apply, no re-grant needed.
create or replace function submit_same_day_request(
  p_staff_id uuid,
  p_tdis text,
  p_request_type text,
  p_pto_balance numeric,
  p_sick_balance numeric,
  p_note text,
  p_actual_time text default null,
  p_hours_impact numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff;
  v_row same_day_requests;
begin
  select * into v_staff from staff where id = p_staff_id and active = true;
  if v_staff is null then
    raise exception 'staff_not_found' using errcode = 'P0001';
  end if;
  if v_staff.tdis_number is null or btrim(upper(v_staff.tdis_number)) <> btrim(upper(p_tdis)) then
    raise exception 'tdis_mismatch' using errcode = 'P0001';
  end if;
  if p_request_type not in ('late_arrival','left_early') then
    raise exception 'invalid_request_type' using errcode = 'P0001';
  end if;

  insert into same_day_requests (
    staff_id, request_type, request_date, pto_balance, sick_balance, note, actual_time, hours_impact
  ) values (
    p_staff_id, p_request_type, current_date, p_pto_balance, p_sick_balance, p_note, p_actual_time, p_hours_impact
  )
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;
