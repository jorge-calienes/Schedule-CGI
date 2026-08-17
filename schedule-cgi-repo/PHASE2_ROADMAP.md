# Phase 2 roadmap — from here to a fully functional app

This picks up where `SETUP_GUIDE.md`'s migration table leaves off. Steps 1–2
are done (PR #1); this document sequences steps 3–6 plus the extra screens
shown in the "Phase 2 mockups" reference (Manage accounts, Staff performance,
Team dashboard) that weren't in the original numbered list but are needed for
a fully functional app.

Same ground rules as before: one slice at a time, each as its own PR, each
tested against the real Supabase project before moving to the next. Nothing
here should be built in one giant rewrite.

## Where things stand today

| Piece | Status |
|---|---|
| Sign-in (`signInWithPin`, session restore) | **Done** — PR #1 |
| Board data read (`state.areas`/`staff`/`assignments` ← `loadBoard()`) | **Done** — PR #1 |
| Board data *writes* (move/swap/callout/staff/area edits) | Still localStorage only |
| Rotate Now / history | Still localStorage only |
| Evaluation form, team-lead queue | Not built (client functions already exist, unused) |
| Audit log screen | Not built (client function already exists, unused) |
| Manage accounts (grant/request) | Not built (API routes exist, unused) |
| Staff performance profile, Team dashboard | Not built, no client functions yet either |

The mockup you shared is UI reference only — none of its screens are wired
to anything yet. This roadmap is how we get from "reference" to "real."

## Recommended order

### 1. Step 3a — Move / swap / callout write path + audit_log
The big one. Every board mutation (move, swap, mark someone out, clear
callout) needs to write to the real `assignments`/`callouts` tables and
insert an `audit_log` row, instead of only touching local `state`. This is
the moment the board actually becomes live/shared between people.

Recommend an optimistic-write helper (fire the Supabase call in the
background after the local `state` update, toast on failure) rather than
converting each of the many call sites to `await` a network round trip —
keeps the board feeling instant.

**Watch out for:** `state.blocks`, `state.timeOff`, `state.calloutHistory`,
etc. are still keyed by the *old* localStorage/demo staff ids. Since Step 2
already swapped `state.staff`/`state.areas` over to real Supabase UUIDs,
those side-tables are already silently mismatched today. Step 3 is the
right time to fix this — either migrate `time_off` to its Supabase table in
the same pass (it already exists with RLS policies), or explicitly reset
the local-only ones once real UUIDs are in play.

### 2. Step 3b — Staff / area CRUD write path + audit_log
Add/edit/archive staff, add/edit areas → `staff`/`areas` tables + audit_log.
Split from 3a to keep each PR reviewable; same pattern.

### 3. Step 4 — Rotate Now → `rotation_periods` / `rotation_period_assignments`
Depends on Step 3 (needs live `assignments` to snapshot). Insert a period +
snapshot rows when "Rotate Now" runs. Recommend loading `state.history` back
from Supabase the same way Step 2 did for board data, so the History view
reads real data too.

### 4. Step 5 — Evaluation form + "My evaluations" queue ⭐
The actual new Phase 2 feature. No localStorage equivalent exists, so this
can go straight to Supabase with no parallel-track risk — genuinely the
lowest-risk substantial feature to build, and doesn't need to wait on Step
3/4 at all if we want to pull it forward.

`submitEvaluation()` and `myEvaluationQueue()` already exist in
`lib/supabaseClient.js` and are already on `window.RC`. New UI needed:
- A "My evaluations" nav item visible only when
  `authState.account.role === 'team_lead'`, listing `myEvaluationQueue()`.
- The evaluation form itself (mockup screen 3), scored 1–5 on
  productivity/performance/reliability + a recommendation.
- Supervisors/admins need a *different* entry point — `eval_insert`'s RLS
  lets managers evaluate anyone, not just a queue, so this probably hangs
  off the Roster/staff profile rather than a queue view.

### 5. Step 6 — Audit log screen
`fetchAuditLog()` already exists and is bridged. Purely additive, read-only,
supervisor/admin only. **Caveat:** until Step 3 ships, this will only show
evaluation submissions and account grants — no moves/swaps/rotations yet.
Worth an empty-state hint rather than looking broken. Low risk enough that
it could go before Step 5 instead, if preferred.

### 6. Manage accounts (mockup screen "accounts")
Not in the original 6-step list, but the actual bottleneck to "fully
functional" — right now there's exactly one admin account (the manually
seeded one from `SETUP_GUIDE.md`), and nobody else can get in. Admin-only.
Two parts:
- **Pending requests** — list accounts with `status='pending'` (RLS already
  allows admins to see everyone). Also means finally adding the "Request
  access" link to the sign-in screen — `requestAccess()` is already bridged
  through `window.RC` but nothing calls it yet.
- **Grant flow** — needs a new `grantAccess()` client function that POSTs to
  `/api/accounts/grant` with the signed-in admin's `access_token` as a
  Bearer header (that route re-verifies admin status server-side with the
  service-role key — see `api/accounts/grant.js`). This is the one screen
  in this whole roadmap that talks to a custom API route instead of
  querying Supabase tables directly.

### 7. Staff performance profile, then Team dashboard (mockup screens 4 & 5)
Read-only aggregations over `evaluations` (avg scores, trend over time,
latest recommendation per person). No client functions exist yet — will
need something like `fetchStaffEvaluationHistory(staffId)` and
`fetchTeamPerformanceOverview()`. Do these last: they're only useful once
there's real evaluation history to show, which means Step 5 needs to have
been live for at least one rotation period first.

## Cross-cutting decision (already settled)

Role-based visibility (nav items, screens) is driven purely by the signed-in
account's real `role` from `authState.account` — no manual "preview as"
switcher like the mockup's dev toggle. Applies to every screen above.

## Suggested next step

Step 3a (move/swap/callout writes + audit_log) is next in line per the
original plan, but it's also the highest-risk item — dozens of call sites,
real shared state, the local-id/Supabase-uuid mismatch to untangle. Worth
explicitly confirming before starting, or alternatively pulling Step 5
(evaluation form) forward first since it's lower-risk and delivers the
headline new feature sooner. Your call.
