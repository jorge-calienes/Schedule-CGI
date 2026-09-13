-- Staff display order within an area — mirrors areas.sort_order /
-- departments.sort_order. Dragging a chip onto another chip in the same
-- area (or the mobile "Move up"/"Move down" chip-menu buttons) persists
-- through this column instead of reverting to insertion order on reload.
--
-- Backfills a migration that was applied directly to the live project when
-- this feature shipped (PR #52) without a checked-in file — added here so a
-- fresh environment rebuilt from these migrations gets the same column.
alter table assignments add column if not exists sort_order integer not null default 0;
