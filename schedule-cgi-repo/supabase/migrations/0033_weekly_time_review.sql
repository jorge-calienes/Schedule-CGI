-- Weekly Time Review (Phase 2) — persists what Phase 1 only kept in the
-- open modal's own state: the uploaded punches themselves (so reopening a
-- week doesn't mean re-uploading the file) and each review decision
-- (verify a day, approve/not-approve a late start, a corrected punch
-- time), so they survive a reload and are visible from another device —
-- same bug class state.coverage/state.teamLeadCoverage were in before
-- their own sync migrations.
--
-- Same "any signed-in manager can read/write" shape as every other
-- manager-only table here (positions, coverage_waivers, temp_moves,
-- position_requests, proficiency_ratings, team_lead_coverage_events) —
-- team scoping ("just my team") is a UI-layer concern in index.html
-- (myReviewTeamStaff()), same as it already is for Team dashboard and
-- Attendance report; no table here is RLS-scoped to a single supervisor,
-- and this one doesn't start being the exception.

-- One row per punch, exactly as read off the uploaded export — the
-- analysis/derivation logic (trAnalyzeDay/trDeriveDay in index.html) stays
-- entirely client-side and re-runs over these rows every time, so nothing
-- about the heuristics needs to live in the database.
create table time_review_punches (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references staff(id) on delete cascade,
  week_start     date not null,
  day            date not null,
  description    text not null,
  punch_minutes  numeric not null, -- minutes since midnight, same unit trParseTime() already uses
  uploaded_by    uuid references accounts(id),
  uploaded_at    timestamptz not null default now()
);
create index time_review_punches_week_idx on time_review_punches(week_start);
create index time_review_punches_staff_day_idx on time_review_punches(staff_id, day);

-- One row per person-day that a supervisor has actually acted on — most
-- person-days never get a row here at all (nothing to decide). fix holds
-- a manually-entered/corrected punch time per slot index (0-5, matching
-- TR_SLOTN in index.html), e.g. {"4": "12:50"}.
create table time_review_decisions (
  staff_id       uuid not null references staff(id) on delete cascade,
  day            date not null,
  verified       text,                              -- 'Yes' | null
  late_approved  text,                              -- 'Yes' | 'No' | null
  late_note      text not null default '',
  fix            jsonb not null default '{}'::jsonb,
  decided_by     uuid references accounts(id),
  decided_at     timestamptz not null default now(),
  primary key (staff_id, day)
);

alter table time_review_punches enable row level security;
alter table time_review_decisions enable row level security;

create policy time_review_punches_select on time_review_punches for select
  using (is_manager());
create policy time_review_punches_write on time_review_punches for all
  using (is_manager()) with check (is_manager());

create policy time_review_decisions_select on time_review_decisions for select
  using (is_manager());
create policy time_review_decisions_write on time_review_decisions for all
  using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table time_review_punches;
alter publication supabase_realtime add table time_review_decisions;
