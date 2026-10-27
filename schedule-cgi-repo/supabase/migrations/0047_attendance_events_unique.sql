-- Fixes duplicate callout/late-arrival/left-early events inflating the
-- Attendance Report. index.html's client-side idempotency check
-- (recordCalloutAttendanceEvent) only guards against a second insert
-- within one already-loaded page's own in-memory state — a realtime
-- refresh racing a still-in-flight insert can wipe that local state
-- before it commits, so a duplicate still reaches the database. This is
-- the actual fix: the database itself now refuses a second row for the
-- same person/event type/day, whichever client gets there first.
--
-- staff_id, event_type, event_date was already proven duplicate-free in
-- production right before this migration (all 70+ stray historical
-- duplicates, back to 2026-08-26, were cleaned up first).
alter table attendance_events
  add constraint attendance_events_staff_type_date_unique
  unique (staff_id, event_type, event_date);
