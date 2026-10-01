-- Staff proficiency ratings (per staff, per area — gates flow advancement)
-- were local-only (state.proficiency, written by saveAreaRating() with only
-- a saveState() call, no Supabase write at all) — same bug class
-- state.coverage was in before 0007_coverage_sync.sql fixed it: a rating
-- given on one device/kiosk is invisible everywhere else, and doesn't
-- survive a cleared cache. Unlike reassignment/position requests, a rating
-- isn't a pending request to review — it's a durable fact (set once per
-- rotation-advancement decision, during Rotate Now or the flow-advancement
-- feedback modal), so this is a plain append-only log, not a status-workflow
-- table: every call site already treats it that way (saveAreaRating()
-- pushes one more entry onto a staff/area's rating history and recomputes
-- the latest composite score from it).
--
-- `period` stays a free-text label (matching state.currentPeriod's existing
-- shape) rather than a rotation_periods FK — the rest of this proficiency
-- system (getAreaRating/getAreaRatingHistory/isProficiencyBlocked) only
-- ever displays it as a label, never joins on it.
--
-- Both the rating and the decision to advance someone despite a low rating
-- happen in the same supervisor-only flows (Rotate Now's confirm step, the
-- flow-advancement feedback modal's approve/block actions) — a team lead's
-- own rating input is captured earlier into state.pendingFeedback (already
-- local-only/transient — cleared every Rotate Now regardless of this
-- table) and only reaches this table once a supervisor's action writes it.

create table proficiency_ratings (
  id                  uuid primary key default gen_random_uuid(),
  staff_id            uuid not null references staff(id) on delete cascade,
  area_id             uuid not null references areas(id) on delete cascade,
  period              text,
  team_lead_rating    smallint not null default 0,
  team_lead_id        uuid references accounts(id),
  team_lead_note      text,
  supervisor_rating   smallint not null default 0,
  supervisor_id       uuid references accounts(id),
  supervisor_approved boolean not null default false,
  override_reason     text,
  created_at          timestamptz not null default now()
);

create index proficiency_ratings_staff_area_idx on proficiency_ratings(staff_id, area_id, created_at);

alter table proficiency_ratings enable row level security;

-- Same "any signed-in user can read, only a manager can write" shape as
-- positions/coverage_waivers/temp_moves/position_requests — a team lead
-- never writes this table directly (see above), only reads it (best-fit
-- suggestions, staff stats) alongside everyone else.
create policy proficiency_ratings_select on proficiency_ratings for select
  using ((select auth.uid()) is not null);
create policy proficiency_ratings_write on proficiency_ratings for all
  using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table proficiency_ratings;
