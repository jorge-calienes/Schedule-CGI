-- Area capacity has only ever been enforced client-side (attemptPlace()'s
-- own "capacity-full" check, against whatever board state that client last
-- loaded). Two people on two different devices placing into the last open
-- slot of the same area at the same moment can both pass their own,
-- possibly-stale check and both succeed, silently overfilling the area.
-- This is the backstop for that: a DB-level check a stale client read
-- can't talk its way around.
--
-- Deferred to the end of the transaction (not evaluated immediately per
-- row) so a swap's two-row upsert — which briefly has both people "in"
-- each other's destination area until the second row lands — is judged on
-- its FINAL state, not an intermediate one. A swap can never actually
-- change either area's headcount (see doSwap()'s own comment to that
-- effect), so it should never trip this.
--
-- A called-out occupant doesn't count against capacity, matching the
-- client's own activeInArea() exclusion. An active temp_moves or
-- coverage_assignments row for the staff being placed exempts that one
-- placement, matching attemptPlace()'s/assignCoverage()'s own rule that a
-- scoped move is backup coverage on top of who's already there and is
-- allowed to push an area over capacity. That exemption is checked by the
-- sibling row's existence — since the client writes the scoped-move
-- record and the board-position move as two separate requests rather than
-- one transaction, there's a narrow window where this can fire before
-- that row lands. That's an accepted gap in a backstop, not a
-- replacement for the client's own enforcement, which still runs first
-- for every write that goes through the normal UI.
create or replace function enforce_area_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cap int;
  occupied int;
begin
  if new.area_id is null then
    return new;
  end if;

  -- Serializes concurrent writers targeting the same area so the count
  -- below can't be read stale by a second transaction racing this one —
  -- without this, two concurrent transactions could each see "room for
  -- one more" from their own snapshot and both commit.
  perform pg_advisory_xact_lock(hashtext(new.area_id::text));

  if exists (select 1 from temp_moves where staff_id = new.staff_id)
     or exists (select 1 from coverage_assignments where staff_id = new.staff_id) then
    return new;
  end if;

  select capacity into cap from areas where id = new.area_id;
  if cap is null then
    return new; -- area missing/archived — nothing sane to enforce
  end if;

  select count(*) into occupied
    from assignments a
    where a.area_id = new.area_id
      and not exists (select 1 from callouts c where c.staff_id = a.staff_id);

  if occupied > cap then
    raise exception 'Area capacity reached (% placed, % allowed)', occupied, cap;
  end if;

  return new;
end;
$$;

create constraint trigger assignments_capacity_check
  after insert or update of area_id on assignments
  deferrable initially deferred
  for each row
  execute function enforce_area_capacity();

-- This is a trigger helper, not something meant to be called directly as an
-- RPC (PostgREST auto-exposes every public-schema function by default).
-- Calling it outside trigger context would already fail — NEW/OLD aren't
-- bound — but revoke execute anyway to keep it off the API surface.
revoke execute on function enforce_area_capacity() from public, anon, authenticated;
