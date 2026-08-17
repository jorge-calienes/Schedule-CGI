// POST /api/accounts/request   { name: "Rafael Ortiz" }
//
// Anyone can call this — it just creates a 'pending' account row with no
// PIN and no linked login yet. It shows up in the admin's "Manage accounts"
// screen (pending requests) until an admin grants it via /api/accounts/grant.

import { createClient } from '@supabase/supabase-js';

export default async function handler(req, res) {
  // See pin-login.js for why this is all wrapped: an uncaught throw here
  // crashes the function and Vercel's non-JSON error page then fails to
  // parse client-side with a confusing, unrelated-looking error.
  try {
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('accounts/request: missing SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY env vars');
      return res.status(500).json({ error: 'Server is misconfigured (missing Supabase credentials). Contact an admin.' });
    }

    const supabaseAdmin = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const { name } = req.body || {};
    if (!name || name.trim().length < 2) {
      return res.status(400).json({ error: 'Enter your full name.' });
    }

    const { data: existing } = await supabaseAdmin
      .from('accounts')
      .select('id, status')
      .ilike('name', name.trim())
      .maybeSingle();

    if (existing) {
      return res.status(200).json({
        message: existing.status === 'pending'
          ? 'You already have a request waiting on approval.'
          : 'An account with that name already exists — ask an admin if you need access restored.',
      });
    }

    const { error } = await supabaseAdmin
      .from('accounts')
      .insert({ name: name.trim(), status: 'pending', role: 'team_lead' });

    if (error) return res.status(500).json({ error: 'Could not submit request.' });

    return res.status(200).json({ message: 'Request submitted — an admin needs to approve you before you can sign in.' });
  } catch (e) {
    console.error('accounts/request: unexpected error:', e);
    return res.status(500).json({ error: `Unexpected server error: ${e && e.message || e}` });
  }
}
