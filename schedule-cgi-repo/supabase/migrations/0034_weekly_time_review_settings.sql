-- Weekly Time Review (Phase 3, part 1) — the tolerances index.html's
-- TR_RULES has hardcoded since Phase 1 (late/early grace, expected lunch
-- and break length, how far under/over schedule before flagging it)
-- become editable and persisted, instead of baked into the client. Same
-- singleton-row shape as active_rotation (0019) — one set of rules for
-- the whole operation, not per-supervisor, matching how every other
-- cross-cutting setting here already works (rotationWeeks, etc.).

create table time_review_settings (
  id                   boolean primary key default true,
  late_grace           integer not null default 2,   -- minutes late before it counts as "late"
  early_grace          integer not null default 5,   -- minutes left early before flagged
  lunch_min            integer not null default 60,  -- expected lunch length (minutes)
  lunch_paid           integer not null default 15,  -- paid minutes within the lunch hour
  break_min            integer not null default 15,  -- expected break length (minutes)
  stand_tol            integer not null default 15,  -- minutes under schedule before "keep an eye"
  over_tol             integer not null default 60,  -- minutes over schedule before "keep an eye" (check overtime approval)
  fallback_target_min  integer not null default 480, -- net target used when a person has no shift on file
  updated_by           uuid references accounts(id),
  updated_at           timestamptz not null default now(),
  constraint time_review_settings_singleton check (id)
);

alter table time_review_settings enable row level security;
create policy time_review_settings_select on time_review_settings for select
  using ((select auth.uid()) is not null);
create policy time_review_settings_write on time_review_settings for all
  using (is_manager()) with check (is_manager());

alter publication supabase_realtime add table time_review_settings;

-- Seed the one row up front so a plain select always returns something —
-- the client falls back to the same defaults client-side regardless, but
-- an existing row from the start means "edit the rules" is always
-- updating, never guessing whether to insert or update.
insert into time_review_settings (id) values (true);
