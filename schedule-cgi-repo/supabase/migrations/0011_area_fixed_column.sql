-- The area editor's "Fixed area — staff don't rotate in or out" checkbox
-- has never actually persisted: mapSupabaseBoard() hardcoded fixed:false
-- on every load, and the client never sent `fixed` to createArea/updateArea
-- in the first place. It looked like it worked within a session (the
-- checkbox updates local state immediately) but silently reverted to
-- unfixed on the next reload or realtime sync. Adding a real column so the
-- setting actually round-trips.

alter table areas add column fixed boolean not null default false;
