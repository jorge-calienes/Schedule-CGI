-- A "just for today" move/swap (see 0020_temp_moves.sql) now has a second
-- flavor: "for this rotation" — same auto-revert idea, but only at the next
-- Rotate Now instead of on every day's first load. scope distinguishes the
-- two so reconcileStaleTempMoves() (day-based) knows to leave 'rotation'
-- rows alone and let endAllTempMoves() (Rotate Now) handle them instead.
alter table temp_moves add column scope text not null default 'day'
  check (scope in ('day', 'rotation'));
