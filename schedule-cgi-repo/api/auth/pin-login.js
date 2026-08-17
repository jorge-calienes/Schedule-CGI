// POST /api/auth/pin-login   { name: "Jazmine Torres", pin: "4821" }
//
// This is the ONLY piece of the app allowed to use the Supabase *service
// role* key. It verifies the PIN server-side (via the verify_pin() function
// in 0002_pin_auth.sql), then mints a real Supabase Auth session for that
// account's linked auth.users row and hands the session tokens back to the
// browser. From that point on, the browser talks to Supabase directly with
// the anon key + the session it was just given, and RLS policies apply
// normally because auth.uid() now resolves to a real signed-in user.
//
// Env vars required (set in Vercel project settings, NOT in the frontend):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY   (service_role secret — server only, never shipped to the client)

import { createClient } from '@supabase/supabase-js';

export default async function handler(req, res) {
  // Every path below must return valid JSON — an uncaught throw here (e.g.
  // missing env vars, an unexpected Supabase client error) previously
  // crashed the function and Vercel returned its own non-JSON error page,
  // which the browser's fetch().json() then failed to parse with a
  // confusing "did not match the expected pattern" SyntaxError that looked
  // like a client-side bug. Wrapping everything here means a real failure
  // now always surfaces as a clean, specific message instead.
  try {
    if (req.method !== 'POST') {
      return res.status(405).json({ error: 'Method not allowed' });
    }

    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('pin-login: missing SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY env vars');
      return res.status(500).json({ error: 'Server is misconfigured (missing Supabase credentials). Contact an admin.' });
    }

    const supabaseAdmin = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const { name, pin } = req.body || {};
    if (!name || !pin || !/^\d{4}$/.test(pin)) {
      return res.status(400).json({ error: 'Name and a 4-digit PIN are required.' });
    }

    // Basic per-request rate limiting hint — real deployments should also add
    // an edge/IP rate limit (e.g. Vercel Firewall or Upstash) in front of this route.

    const { data: accountId, error: verifyErr } = await supabaseAdmin.rpc('verify_pin', {
      p_name: name,
      p_pin: pin,
    });

    if (verifyErr || !accountId) {
      // Deliberately generic — don't reveal whether the name or PIN was wrong.
      return res.status(401).json({ error: 'Name or PIN not recognized.' });
    }

    const { data: account, error: acctErr } = await supabaseAdmin
      .from('accounts')
      .select('id, user_id, name, role, status, assigned_area_id')
      .eq('id', accountId)
      .single();

    if (acctErr || !account || account.status !== 'active' || !account.user_id) {
      return res.status(401).json({ error: 'This account is not active yet.' });
    }

    // Mint a session for the linked auth.users row without needing their
    // (unused) password — generateLink + verifyOtp is the standard Supabase
    // pattern for "log this specific user in from a trusted server context".
    const { data: authUser, error: userErr } = await supabaseAdmin.auth.admin.getUserById(account.user_id);
    if (userErr || !authUser?.user?.email) {
      return res.status(500).json({ error: 'Account is not linked to a login. Contact an admin.' });
    }

    const { data: linkData, error: linkErr } = await supabaseAdmin.auth.admin.generateLink({
      type: 'magiclink',
      email: authUser.user.email,
    });
    if (linkErr) {
      console.error('pin-login: generateLink failed:', linkErr);
      return res.status(500).json({ error: 'Could not start a session. Try again.' });
    }

    // Exchange the generated OTP for a real session server-side, so the
    // browser never sees the magic link itself — just the finished tokens.
    const { data: sessionData, error: sessionErr } = await supabaseAdmin.auth.verifyOtp({
      email: authUser.user.email,
      token_hash: linkData.properties.hashed_token,
      type: 'magiclink',
    });
    if (sessionErr || !sessionData?.session) {
      console.error('pin-login: verifyOtp failed:', sessionErr);
      return res.status(500).json({ error: 'Could not start a session. Try again.' });
    }

    return res.status(200).json({
      session: {
        access_token: sessionData.session.access_token,
        refresh_token: sessionData.session.refresh_token,
      },
      account: {
        id: account.id,
        name: account.name,
        role: account.role,
        assigned_area_id: account.assigned_area_id,
      },
    });
  } catch (e) {
    console.error('pin-login: unexpected error:', e);
    return res.status(500).json({ error: `Unexpected server error: ${e && e.message || e}` });
  }
}
