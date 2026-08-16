# Rotation Control — Phase 2 backend setup

This gives you a real database (Supabase/Postgres) behind the app, with
accounts, an audit trail, and evaluations — matching the mockups from the
last round. I can't create the Supabase project or Vercel deployment for
you (no access to those services from here), but everything below is
copy-paste ready.

## What's in this folder

```
backend/
  supabase/migrations/
    0001_init.sql        ← full schema + RLS policies (validated against a real Postgres instance)
    0002_pin_auth.sql     ← PIN sign-in support (validated, including lockout behavior)
  api/
    auth/pin-login.js         ← sign-in: name + PIN → real Supabase session
    accounts/request.js       ← "Request access" (self-serve, lands as pending)
    accounts/grant.js         ← admin approves a pending account
  lib/supabaseClient.js   ← frontend client + example query functions
  package.json
  vercel.json
```

Both SQL migrations were run end-to-end against a local Postgres 16 instance
(with `auth.users`/`auth.uid()` mocked to match Supabase's shape) as part of
writing them, including inserting sample data and testing the PIN lockout
logic. They should apply cleanly, but always still review before running
against production — I can't test against an actual Supabase project from
here, and Supabase's exact Admin API method signatures (`generateLink`,
`verifyOtp`, etc. in `pin-login.js`) are worth a quick check against their
current docs before you rely on them, since I can't hit supabase.com to
verify the very latest signatures.

## 1. Create the Supabase project

1. [supabase.com](https://supabase.com) → New project. Pick a region close to
   your team, set a strong database password (save it somewhere — you won't
   need it day-to-day since the app uses the anon/service keys instead).
2. Once it's provisioned, go to **Project Settings → API** and note down:
   - `Project URL`
   - `anon` `public` key
   - `service_role` `secret` key (⚠️ never put this in frontend code — server/Vercel env vars only)

## 2. Run the migrations

Easiest path — SQL Editor in the Supabase dashboard:

1. **SQL Editor → New query** → paste the entire contents of
   `supabase/migrations/0001_init.sql` → Run.
2. New query again → paste `0002_pin_auth.sql` → Run.

(Or, if you'd rather use the CLI: `supabase link`, drop both files into
`supabase/migrations/`, then `supabase db push`.)

## 3. Create your own admin account (you, per your message)

Since account creation normally goes through the app's grant flow, the very
first admin has to be seeded manually — a one-time bootstrap:

```sql
-- Run in Supabase SQL Editor, once
insert into accounts (name, role, status, approved_at)
values ('Your Name', 'admin', 'active', now())
returning id;
```

Then, from your terminal (or a one-off script) with the service role key,
create the matching auth user and set a PIN — this is exactly what
`grant.js` does programmatically for everyone after you, but for account
#1 there's nobody to click "Grant" yet:

```js
import { createClient } from '@supabase/supabase-js';
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const { data: user } = await admin.auth.admin.createUser({
  email: '<the-account-id-from-above>@rotation.internal',
  email_confirm: true,
});
await admin.from('accounts').update({ user_id: user.user.id }).eq('id', '<account-id>');
await admin.rpc('set_pin', { p_account_id: '<account-id>', p_pin: '1234' });
```

After that, you can sign in through the app UI and use **Manage accounts**
for everyone else — no more manual SQL needed.

## 4. Deploy the API routes to Vercel

1. Push this `backend/` folder to a GitHub repo (or add it alongside the
   existing `rotation-control.html` in the same repo — Vercel can serve
   both a static file and `/api` routes from one project).
2. [vercel.com](https://vercel.com) → New Project → import that repo.
3. **Project Settings → Environment Variables**, add:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY`
   (Both **server-only** — do not prefix them in a way that exposes them to
   the client. Plain names like above are fine since they're only read
   inside `/api/*.js`, which runs server-side on Vercel.)
4. Deploy. Vercel auto-detects the `/api` folder as serverless functions.

## 5. Wire the frontend

1. Open `lib/supabaseClient.js`, fill in your real `SUPABASE_URL` and
   `SUPABASE_ANON_KEY` (the **anon** key — safe for the browser).
2. Host that file alongside `rotation-control.html` and add:
   ```html
   <script type="module" src="/lib/supabaseClient.js"></script>
   ```
3. From here, swap the app's `localStorage`/`window.storage` calls over to
   the functions in `supabaseClient.js` — **recommended order** so you can
   test incrementally rather than one giant rewrite:

   | Step | Replace | Why first/last |
   |---|---|---|
   | 1 | Sign-in screen → `signInWithPin()` | Nothing else matters until people can log in |
   | 2 | `state.areas`/`state.staff`/`state.assignments` load → `loadBoard()` | Core data, everything else depends on it |
   | 3 | Move/swap/callout handlers → write to `assignments`/`callouts` tables + `audit_log` insert | Board becomes live |
   | 4 | Rotate Now → insert into `rotation_periods` + `rotation_period_assignments` | Closes the loop on history |
   | 5 | New: evaluation form → `submitEvaluation()`, team lead queue → `myEvaluationQueue()` | The actual Phase 2 feature |
   | 6 | New: audit log screen → `fetchAuditLog()` | Read-only, low risk, do last |

   I'd suggest we do this step together, one at a time, rather than me
   rewriting the whole 14,000-line file against a backend neither of us can
   click through yet — that way each step is testable against your real
   Supabase project before moving to the next.

## 6. Sanity-check the permission model

Once a few accounts exist, worth manually verifying before rolling out:

- Sign in as a **team lead** → should only see "My evaluations" for people
  currently assigned to their one area, and the evaluation form. No audit
  log, no team dashboard, no staff performance tab (enforced by the RLS
  policies on `evaluations`, `audit_log`, etc. — not just hidden UI).
- Sign in as a **supervisor** → audit log, evaluation form (any staff),
  staff performance, team dashboard. No "Manage accounts".
- Sign in as **admin** (you) → everything, including granting access.

## Notes / things worth deciding before go-live

- **PINs are convenience, not the real security boundary.** The actual
  authentication happens via a real Supabase session minted server-side;
  the PIN is just how a person identifies themselves to get one. If this
  ever needs to be audit-proof for something more sensitive than internal
  scheduling, swap PINs for real passwords or SSO — the RLS layer doesn't
  change either way.
- **Rate limiting**: `pin-login.js` relies on the database-side lockout
  (5 wrong attempts → 15 min lock per account). Consider adding an
  IP-based rate limit in front of it too (Vercel Firewall, or a small
  Upstash Redis counter) so someone can't hammer many different names.
- **Multi-tenant?** This schema assumes one organization. If you'll ever
  run this for more than one client/site, worth adding an `org_id` column
  to nearly every table now rather than retrofitting later — say the word
  and I'll adjust the schema before you run it.
