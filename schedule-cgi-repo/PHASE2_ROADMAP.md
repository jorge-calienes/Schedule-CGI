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
| Move/swap/callout writes + audit_log (Step 3a) | **Done** |
| Staff/area CRUD writes + audit_log (Step 3b) | **Done** |
| Rotate Now / history (Step 4) | **Done** |
| Evaluation form, team-lead queue | Not built (client functions already exist, unused) |
| Audit log screen | Not built (client function already exists, unused) |
| Manage accounts (grant/request) | Not built (API routes exist, unused) |
| Staff performance profile, Team dashboard | Not built, no client functions yet either |

The mockup you shared is UI reference only — none of its screens are wired
to anything yet. This roadmap is how we get from "reference" to "real."

## Recommended order

### ~~1. Step 3a — Move / swap / callout write path + audit_log~~ ✅ Done
Every board mutation (move, swap, mark someone out, clear callout) now
writes to the real `assignments`/`callouts` tables and inserts an
`audit_log` row, via a fire-and-forget `syncBoardWrite()` helper (local
state updates and renders immediately; a failed sync just shows a toast).

**Still open:** `state.blocks`, `state.timeOff`, `state.calloutHistory`,
etc. are still keyed by the *old* localStorage/demo staff ids in any
deployment that had local data before Step 2 shipped. Time-off/coverage
-driven assignment changes are explicitly NOT synced yet (flagged with code
comments at each call site) — that needs the `time_off` feature migrated
first so the ids involved are consistent.

### ~~2. Step 3b — Staff / area CRUD write path + audit_log~~ ✅ Done
Add/edit/archive staff, add/edit/delete areas → `staff`/`areas` tables +
audit_log. Unlike Step 3a's fire-and-forget pattern, these **await** the
Supabase write and show a definitive "Saved to database ✓" / "not saved to
the database" toast before closing the modal — CRUD is a deliberate,
infrequent action where confirmation matters more than instant feedback,
and awaiting also solves a real correctness issue: a brand-new staff/area
record needs the database's generated UUID as its id from the start (the
old `uid('staff')`/`uid('area')` local-id format isn't a valid Postgres
uuid), so creation can't be optimistic the way moves/swaps are. Falls back
to a local-only id + warning toast if the sync fails, so people aren't
blocked by a network hiccup. Department is a free-text field in the UI but
a real FK in the schema — `ensureDepartment()` resolves-or-creates it by
name on every staff/area save.

### ~~3. Step 4 — Rotate Now → `rotation_periods` / `rotation_period_assignments`~~ ✅ Done
"Apply & start new period" now awaits `createRotationPeriod()` (same
await-and-confirm pattern as Step 3b) before closing the modal — it inserts
one `rotation_periods` row plus a `rotation_period_assignments` row per
staff, snapshotting the *closing* period's assignments exactly as they
stood before any flow-advancement moves run. Those advancement moves
(people getting bumped to their next area) now also sync individually via
the same fire-and-forget `moveStaff()` path as Step 3a. `state.history`
loads back from Supabase on boot via `fetchRotationHistory()`, same
pattern as board data in Step 2.

**Still local-only, unchanged:** `endAllCoverage()`'s bulk reassignment —
still coupled to the not-yet-migrated `state.coverage`/`state.timeOff`.

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

Steps 3a, 3b, and 4 are done — the board, staff/area edits, and Rotate Now
are all fully live against Supabase. Step 5 (evaluation form) is next in
line, and also the lowest-risk substantial feature left: no localStorage
equivalent to migrate away from, and the client functions already exist.
