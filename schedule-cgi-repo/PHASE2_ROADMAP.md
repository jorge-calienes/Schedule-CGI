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
| Evaluation form, team-lead queue (Step 5) | **Done** |
| Staff import from Excel/CSV | **Done** |
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

### ~~4. Step 5 — Evaluation form + "My evaluations" queue~~ ✅ Done
A "My evaluations" nav item (visible only when
`authState.account.role === 'team_lead'`) opens a queue modal backed by
`myEvaluationQueue()`, split into "needs feedback" vs "already submitted"
(`existing_evaluation_id` from the view). Tapping a pending row opens the
evaluation form — 1–5 star ratings for productivity/performance/reliability
(reusing the existing `renderStarRating()`/`.star-row` pattern from the
flow-advancement feedback modal) plus a recommendation
(stay/advance/training) and an optional note — which awaits
`submitEvaluation()` via the same `syncCrudWrite()` confirm-on-save pattern
as Step 3b, then returns to a freshly reloaded queue.

Supervisors/admins get a separate entry point since `eval_insert`'s RLS
lets managers evaluate anyone, not just a queue: an "📝 Evaluate" button on
the Stats tab of the staff-manager modal, which returns to that same tab on
submit. Managers always pass `periodId: null` (the in-progress period has
no `rotation_periods` row until Rotate Now closes it — the schema's unique
index already coalesces `period_id` for this), while the team-lead queue
passes whatever `current_period_id` the view resolves (also nullable before
the first Rotate Now).

### ~~5. Staff import from Excel/CSV~~ ✅ Done (pulled forward, ahead of Manage accounts)
Not in the original list — added because onboarding a whole roster by hand
in the Add Staff form doesn't scale. "Import staff (Excel)" (admin/supervisor
nav item) includes a "Download blank template" button (generated client-side
with SheetJS) covering every profile field that's actually wired to
Supabase: Name, TDIS #, Department, Shift, Hire date, Team Lead, AGS/
Subcontractor, Needs Accommodations, Counter Acceptance, Tags. Deliberately
excludes Supervisor, Language certifications, and Rotation flow — those
aren't synced to Supabase anywhere yet, even from the manual form (no
`loadBoard()` fetch, no write path), so importing them would silently not
persist, the same trap `counter_cert` was in below.

Uploading parses the spreadsheet client-side with SheetJS (loaded from
jsDelivr, same CDN as `supabase-js`), auto-detects columns by header name
(stripping "(Y/N)"-style hints before matching) with a manual-remap
fallback, and shows a row-by-row validation preview (missing name,
malformed or duplicate-within-file TDIS). Rows are upserted, not just
created: a row whose TDIS # matches an existing staff member calls
`updateStaff()` instead of `createStaff()`, so re-uploading the same file
after editing it is a real "keep the roster in sync" workflow, not just a
one-time seed. Every row still goes through the same `createStaff()`/
`updateStaff()` path the manual form uses — real Supabase UUIDs and
`audit_log` entries, no separate bulk-write code path to keep in sync.

Building this exposed a real gap: `counter_cert` and `hire_date` were UI
fields (`state.staff[].counterCert`/`.hireDate`, the "✅ Counter Acceptance
certified" toggle and hire-date input in the staff-manager form) that had
**no column in the `staff` table at all** — edits to them silently never
reached the database. Added both columns (migration
`0003_staff_cert_hiredate.sql`) and wired them into `staffRow()`,
`createStaff()`/`updateStaff()`, and `mapSupabaseBoard()`'s read-back, so
the manual form now actually persists them too, not just the importer.

### 6. Step 6 — Audit log screen
`fetchAuditLog()` already exists and is bridged. Purely additive, read-only,
supervisor/admin only. **Caveat:** until Step 3 ships, this will only show
evaluation submissions and account grants — no moves/swaps/rotations yet.
Worth an empty-state hint rather than looking broken. Low risk enough that
it could go before Step 5 instead, if preferred.

### 7. Manage accounts (mockup screen "accounts")
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

### 8. Staff performance profile, then Team dashboard (mockup screens 4 & 5)
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

### Team lead access: evaluations + read-only board

Every write table's RLS policy already requires `is_manager()`
(admin/supervisor) — team leads were always blocked from writing at the
database layer, the UI just didn't reflect it, so a team lead could drag
people around, mark callouts, edit staff, even hit Rotate Now, and only
find out afterward it silently failed to save. `isTeamLeadRole()` (in
`index.html`) closes that gap client-side:
- Nav drawer collapses to "My evaluations" + "Sign out" only.
- `viewMode` is pinned to `'board'` — the Board/Overview/Breaks/Time Off
  tab bar doesn't render, so Roster (which has an inline-editable table)
  and the other view modes aren't reachable at all.
- On the board itself: chips aren't draggable and drop their Move/Swap/
  Out/Edit pills and long-press menu; areas drop their "⋯" edit button and
  drag-to-reorder handle; the "+ Add area" and sidebar "Quick actions"
  (Add work area / Mark someone out) buttons are gone; the callout
  banner's "Assign coverage" action is hidden. Tapping a person's name
  still works, but opens the read-only stats modal (`staff-stats`)
  instead of the editable `staff-manager` one, and that modal's own
  "Edit details" escape hatch is hidden too.

This is a client-side UX fix, not the security boundary — RLS was always
the real enforcement. Verified with headless-Chromium tests for both a
team_lead session (no tab bar, minimal nav, no chip/area actions, name
click opens read-only stats) and an admin session (fully unaffected).

## Suggested next step

Steps 3a, 3b, 4, and 5 are done — the board, staff/area edits, Rotate Now,
and evaluations are all fully live against Supabase. Step 6 (audit log
screen) is next in line: `fetchAuditLog()` already exists and is bridged,
it's purely additive/read-only, and there's now real activity (moves,
CRUD, rotations, evaluations) for it to show.
