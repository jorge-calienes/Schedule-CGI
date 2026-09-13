-- Marks a position (e.g. Cashier CA1) as a single-station hire who never
-- cross-trains into other areas. Staff assigned to such a position are
-- skipped by the Experience gaps report, the "Ready for a new path" nudge,
-- and the per-staff "Best fit to cover X" suggestion — all of which are
-- cross-training nudges that don't apply to them. Defaults to true so every
-- existing position (and any staff without a position) is unaffected.
alter table positions add column if not exists rotates boolean not null default true;
