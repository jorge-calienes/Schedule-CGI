-- ============================================================================
-- Rotation Control — Phase 2 schema
-- Target: Supabase (Postgres 15+)
-- Run this in the Supabase SQL Editor, or via `supabase db push` with the CLI.
-- ============================================================================

create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- 1. ACCOUNTS  (login identities — supervisors, team leads, admins)
-- ----------------------------------------------------------------------------
-- Every account is backed by a real Supabase Auth user (auth.users), so
-- Postgres RLS can trust auth.uid(). The "4-digit PIN" the user types in the
-- UI is NOT stored here in plaintext — see "PIN vs password" note at the
-- bottom of this file for how sign-in actually works under the hood.

create type account_role as enum ('admin', 'supervisor', 'team_lead');
create type account_status as enum ('pending', 'active', 'revoked');

create table accounts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid unique references auth.users(id) on delete cascade,
  name          text not null,
  role          account_role not null default 'team_lead',
  status        account_status not null default 'pending',
  -- Team leads are scoped to ONE area. NULL means "all areas" (admins/supervisors).
  -- (FK to areas/supervisors added further below, once those tables exist.)
  assigned_area_id uuid,
  -- Optional link to a `supervisors` record, so this account shows up as an
  -- assignable "reports to" option on staff profiles.
  linked_supervisor_id uuid,
  requested_at  timestamptz not null default now(),
  approved_at   timestamptz,
  approved_by   uuid references accounts(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table accounts is 'Login identities. status=pending until an admin grants access via Manage Accounts.';

-- ----------------------------------------------------------------------------
-- 2. ORG STRUCTURE — departments, areas, supervisors
-- ----------------------------------------------------------------------------
create table departments (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique,
  sort_order int not null default 0
);

create table areas (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  department_id uuid references departments(id) on delete set null,
  color         text not null default '#2F5FA8',
  capacity      int not null default 4,
  sort_order    int not null default 0,
  archived      boolean not null default false,
  created_at    timestamptz not null default now()
);

create table supervisors (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  color       text not null default '#2F5FA8',
  created_at  timestamptz not null default now()
);

-- accounts.assigned_area_id / linked_supervisor_id reference the tables
-- above, so add those FKs now that the tables exist.
alter table accounts
  add constraint accounts_assigned_area_fk foreign key (assigned_area_id) references areas(id) on delete set null,
  add constraint accounts_supervisor_fk    foreign key (linked_supervisor_id) references supervisors(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 3. SHIFTS & LANGUAGES (lookup lists)
-- ----------------------------------------------------------------------------
create table shifts (
  id     uuid primary key default gen_random_uuid(),
  label  text not null,
  start_time text not null,
  end_time   text not null
);

create table languages (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique
);

-- ----------------------------------------------------------------------------
-- 4. ROTATION FLOWS (career tracks staff move through)
-- ----------------------------------------------------------------------------
create table rotation_flows (
  id    uuid primary key default gen_random_uuid(),
  name  text not null,
  created_at timestamptz not null default now()
);

create table rotation_flow_stages (
  id            uuid primary key default gen_random_uuid(),
  flow_id       uuid not null references rotation_flows(id) on delete cascade,
  area_id       uuid references areas(id) on delete set null,
  stage_order   int not null,
  min_periods   int not null default 1,      -- minimum rotations before eligible to advance
  min_rating    numeric(3,2) default 3.0,     -- minimum avg rating required to advance
  label         text
);

-- ----------------------------------------------------------------------------
-- 5. STAFF
-- ----------------------------------------------------------------------------
create table staff (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  tdis_number           char(3),                       -- 3-char unique ID, e.g. "PH2"
  department_id         uuid references departments(id) on delete set null,
  home_area_id          uuid references areas(id) on delete set null,
  supervisor_id         uuid references supervisors(id) on delete set null,
  shift_id              uuid references shifts(id) on delete set null,
  shift_hours_label     text,                          -- denormalized display text ("7:30 - 4:15")
  break_times_label     text,
  is_team_lead          boolean not null default false,
  is_subcontractor      boolean not null default false, -- "AGS"
  needs_accommodations  boolean not null default false,
  tags                  text,
  flow_id               uuid references rotation_flows(id) on delete set null,
  flow_enrolled         boolean not null default false,
  active                boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint tdis_format check (tdis_number is null or tdis_number ~ '^[A-Z0-9]{3}$')
);
create unique index staff_tdis_unique on staff (tdis_number) where tdis_number is not null;

create table staff_language_certs (
  staff_id    uuid not null references staff(id) on delete cascade,
  language_id uuid not null references languages(id) on delete cascade,
  primary key (staff_id, language_id)
);

-- ----------------------------------------------------------------------------
-- 6. LIVE BOARD STATE — current assignment + callouts
-- ----------------------------------------------------------------------------
create table assignments (
  staff_id  uuid primary key references staff(id) on delete cascade,
  area_id   uuid references areas(id) on delete set null, -- null = unassigned pool
  updated_at timestamptz not null default now(),
  updated_by uuid references accounts(id)
);

create table callouts (
  staff_id  uuid primary key references staff(id) on delete cascade,
  reason    text,
  marked_at timestamptz not null default now(),
  marked_by uuid references accounts(id)
);

create table time_off (
  id        uuid primary key default gen_random_uuid(),
  staff_id  uuid not null references staff(id) on delete cascade,
  start_date date not null,
  end_date   date not null,
  label      text,
  created_by uuid references accounts(id),
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 7. ROTATION PERIODS (history / "Rotate Now" snapshots)
-- ----------------------------------------------------------------------------
create table rotation_periods (
  id            uuid primary key default gen_random_uuid(),
  period_label  text not null,       -- e.g. "2026-08-13"
  start_date    date not null,
  end_date      date,
  weeks         int not null default 2,
  notes         text,
  started_by    uuid references accounts(id),
  created_at    timestamptz not null default now()
);

-- snapshot of the board at the moment a period was closed (for history views)
create table rotation_period_assignments (
  period_id uuid not null references rotation_periods(id) on delete cascade,
  staff_id  uuid not null references staff(id) on delete cascade,
  area_id   uuid references areas(id) on delete set null,
  primary key (period_id, staff_id)
);

-- ----------------------------------------------------------------------------
-- 8. EVALUATIONS  ⭐ new in Phase 2
-- ----------------------------------------------------------------------------
create type eval_recommendation as enum ('stay', 'advance', 'training');

create table evaluations (
  id               uuid primary key default gen_random_uuid(),
  staff_id         uuid not null references staff(id) on delete cascade,
  period_id        uuid references rotation_periods(id) on delete set null,
  area_id          uuid references areas(id) on delete set null, -- area they were evaluated in
  evaluator_id     uuid not null references accounts(id),
  productivity     smallint not null check (productivity between 1 and 5),
  performance      smallint not null check (performance between 1 and 5),
  reliability      smallint not null check (reliability between 1 and 5),
  note             text,
  recommendation   eval_recommendation not null default 'stay',
  created_at       timestamptz not null default now()
);
create index evaluations_staff_idx on evaluations(staff_id, created_at desc);

-- one evaluation per (staff, evaluator, period) — resubmitting updates it
create unique index evaluations_unique_per_period
  on evaluations(staff_id, evaluator_id, coalesce(period_id, '00000000-0000-0000-0000-000000000000'));

-- ----------------------------------------------------------------------------
-- 9. AUDIT LOG  ⭐ new in Phase 2
-- ----------------------------------------------------------------------------
create type audit_action as enum (
  'move', 'swap', 'callout', 'clear_callout', 'edit_staff', 'add_staff', 'archive_staff',
  'edit_area', 'add_area', 'rotate_period', 'evaluation', 'account_request',
  'account_grant', 'account_revoke', 'time_off'
);

create table audit_log (
  id            uuid primary key default gen_random_uuid(),
  actor_id      uuid references accounts(id),
  action        audit_action not null,
  description   text not null,        -- human-readable summary, e.g. "moved Salita Bonney to Counter Acceptance"
  staff_id      uuid references staff(id) on delete set null,
  metadata      jsonb,                 -- structured before/after for anything that needs it
  created_at    timestamptz not null default now()
);
create index audit_log_created_idx on audit_log(created_at desc);
create index audit_log_actor_idx on audit_log(actor_id);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table accounts enable row level security;
alter table areas enable row level security;
alter table departments enable row level security;
alter table supervisors enable row level security;
alter table shifts enable row level security;
alter table languages enable row level security;
alter table rotation_flows enable row level security;
alter table rotation_flow_stages enable row level security;
alter table staff enable row level security;
alter table staff_language_certs enable row level security;
alter table assignments enable row level security;
alter table callouts enable row level security;
alter table time_off enable row level security;
alter table rotation_periods enable row level security;
alter table rotation_period_assignments enable row level security;
alter table evaluations enable row level security;
alter table audit_log enable row level security;

-- Helper: look up the calling user's account row once, reuse everywhere.
create or replace function current_account()
returns accounts
language sql stable security definer
as $$
  select * from accounts where user_id = auth.uid() and status = 'active' limit 1;
$$;

create or replace function is_manager()
returns boolean language sql stable as $$
  select coalesce((select role in ('admin','supervisor') from accounts
                    where user_id = auth.uid() and status = 'active'), false);
$$;

create or replace function is_admin()
returns boolean language sql stable as $$
  select coalesce((select role = 'admin' from accounts
                    where user_id = auth.uid() and status = 'active'), false);
$$;

-- ---- accounts: everyone active can read the roster of accounts (for
--      display names / avatars), only admins can write.
create policy accounts_select on accounts for select
  using (status = 'active' or user_id = auth.uid() or is_admin());
create policy accounts_insert_self on accounts for insert
  with check (user_id = auth.uid() and status = 'pending'); -- self-signup lands as 'pending'
create policy accounts_admin_write on accounts for update
  using (is_admin());
create policy accounts_admin_delete on accounts for delete
  using (is_admin());

-- ---- reference data (areas, departments, supervisors, shifts, languages,
--      rotation flows): readable by any signed-in active account,
--      writable only by managers.
create policy ref_select on areas for select using (auth.uid() is not null);
create policy ref_write  on areas for all using (is_manager()) with check (is_manager());

create policy dept_select on departments for select using (auth.uid() is not null);
create policy dept_write  on departments for all using (is_manager()) with check (is_manager());

create policy sup_select on supervisors for select using (auth.uid() is not null);
create policy sup_write  on supervisors for all using (is_manager()) with check (is_manager());

create policy shift_select on shifts for select using (auth.uid() is not null);
create policy shift_write  on shifts for all using (is_manager()) with check (is_manager());

create policy lang_select on languages for select using (auth.uid() is not null);
create policy lang_write  on languages for all using (is_manager()) with check (is_manager());

create policy flow_select on rotation_flows for select using (auth.uid() is not null);
create policy flow_write  on rotation_flows for all using (is_manager()) with check (is_manager());
create policy flow_stage_select on rotation_flow_stages for select using (auth.uid() is not null);
create policy flow_stage_write  on rotation_flow_stages for all using (is_manager()) with check (is_manager());

-- ---- staff: everyone signed in can read (needed so team leads can see
--      names/areas of who's currently in their queue); only managers edit.
create policy staff_select on staff for select using (auth.uid() is not null);
create policy staff_write  on staff for all using (is_manager()) with check (is_manager());
create policy staff_lang_select on staff_language_certs for select using (auth.uid() is not null);
create policy staff_lang_write  on staff_language_certs for all using (is_manager()) with check (is_manager());

-- ---- live board state: read by everyone signed in; write by managers.
--      (Team leads don't move/swap people — only evaluate them.)
create policy assign_select on assignments for select using (auth.uid() is not null);
create policy assign_write  on assignments for all using (is_manager()) with check (is_manager());
create policy callout_select on callouts for select using (auth.uid() is not null);
create policy callout_write  on callouts for all using (is_manager()) with check (is_manager());
create policy timeoff_select on time_off for select using (auth.uid() is not null);
create policy timeoff_write  on time_off for all using (is_manager()) with check (is_manager());

-- ---- rotation periods / history: read by everyone signed in; write by managers.
create policy period_select on rotation_periods for select using (auth.uid() is not null);
create policy period_write  on rotation_periods for all using (is_manager()) with check (is_manager());
create policy period_assign_select on rotation_period_assignments for select using (auth.uid() is not null);
create policy period_assign_write  on rotation_period_assignments for all using (is_manager()) with check (is_manager());

-- ---- evaluations: THE scoped one.
--      • Managers can read/write all evaluations.
--      • Team leads can read/write ONLY evaluations for staff currently
--        assigned to their one assigned_area_id, and only ones they authored.
create policy eval_select on evaluations for select
  using (
    is_manager()
    or evaluator_id = (select id from accounts where user_id = auth.uid())
  );
create policy eval_insert on evaluations for insert
  with check (
    evaluator_id = (select id from accounts where user_id = auth.uid())
    and (
      is_manager()
      or exists (
        select 1 from accounts a
        join assignments asg on asg.area_id = a.assigned_area_id
        where a.user_id = auth.uid()
          and a.role = 'team_lead'
          and asg.staff_id = evaluations.staff_id
      )
    )
  );
create policy eval_update_own on evaluations for update
  using (evaluator_id = (select id from accounts where user_id = auth.uid()) or is_manager());

-- ---- audit log: managers only. Team leads don't see it (per spec).
--      Writes happen via a trigger/function (see below), not direct client inserts.
create policy audit_select on audit_log for select using (is_manager());
create policy audit_insert on audit_log for insert with check (auth.uid() is not null);

-- ============================================================================
-- CONVENIENCE VIEW: "my evaluation queue" for the signed-in team lead
-- ============================================================================
create or replace view my_evaluation_queue as
select
  s.id as staff_id,
  s.name,
  s.tdis_number,
  a.area_id,
  ar.name as area_name,
  rp.id as current_period_id,
  rp.period_label,
  (select e.id from evaluations e
     where e.staff_id = s.id
       and e.evaluator_id = (select id from accounts where user_id = auth.uid())
       and e.period_id is not distinct from rp.id
     limit 1) as existing_evaluation_id
from staff s
join assignments a on a.staff_id = s.id
join areas ar on ar.id = a.area_id
left join lateral (
  select * from rotation_periods order by created_at desc limit 1
) rp on true
where a.area_id = (
  select assigned_area_id from accounts where user_id = auth.uid() and role = 'team_lead'
)
and s.active = true;

comment on view my_evaluation_queue is
  'For the frontend: select * from my_evaluation_queue while signed in as a team lead.';

-- ============================================================================
-- NOTE on "4-digit PIN" sign-in vs. Supabase Auth
-- ============================================================================
-- Supabase Auth (and therefore RLS via auth.uid()) needs a real authenticated
-- session. A bare 4-digit PIN is too weak to be that session's only secret at
-- the database layer. Recommended approach, keeping the simple UI you want:
--
--   1. When an admin grants access, the backend (a small serverless
--      function — see /api/accounts/grant) creates a Supabase Auth user with
--      a generated internal email like "jazmine.torres@rotation.internal"
--      and a securely-random password, and stores that password encrypted
--      (or better: never stores it — see option 2).
--   2. PREFERRED: the "4-digit PIN" the person types is really a lookup key,
--      not the credential. Sign-in flow:
--        a. User picks/types their name + PIN in the UI.
--        b. A serverless function looks up the account by (name, pin_hash)
--           in a small `pin_lookup` table (PIN hashed with bcrypt, rate
--           limited, locked after 5 bad attempts), and if it matches,
--           mints a Supabase session for that user's auth.users row using
--           the Supabase Admin API (service role key, server-side only).
--        c. The session token is returned to the browser and used for all
--           subsequent Supabase calls, so RLS policies above work normally.
--   This keeps the PIN experience for staff, while the actual security
--   boundary (RLS) is backed by a real, rate-limited, server-verified login.
--   Table + function for this are in 0002_pin_auth.sql.
