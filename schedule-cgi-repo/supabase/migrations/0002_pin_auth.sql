-- ============================================================================
-- PIN-based sign-in support
-- ============================================================================
-- Staff type their name + 4-digit PIN. This table maps that PIN (hashed) to
-- an account, with rate limiting. The actual Supabase session is minted by a
-- server-side function using the service role key (see /api/auth/pin-login.js)
-- — this table never talks directly to the browser.

create extension if not exists "pgcrypto";

create table pin_lookup (
  account_id      uuid primary key references accounts(id) on delete cascade,
  pin_hash        text not null,           -- bcrypt hash via crypt(pin, gen_salt('bf'))
  failed_attempts smallint not null default 0,
  locked_until    timestamptz,
  updated_at      timestamptz not null default now()
);

alter table pin_lookup enable row level security;
-- No client-side access at all — only the service role (server) touches this table.
create policy pin_lookup_no_client_access on pin_lookup for all using (false);

-- Called by the server (service role) when an admin grants access or a user
-- resets their PIN. Never called from the browser with the anon key.
create or replace function set_pin(p_account_id uuid, p_pin text)
returns void
language plpgsql
security definer
as $$
begin
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
  insert into pin_lookup(account_id, pin_hash)
  values (p_account_id, crypt(p_pin, gen_salt('bf')))
  on conflict (account_id) do update
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null, updated_at = now();
end;
$$;

-- Called by the server (service role) during sign-in. Returns the matching
-- account_id on success, or NULL on any failure (unknown name, wrong PIN,
-- or locked account — deliberately not distinguished, so the API can't be
-- used to enumerate valid names). Returning NULL instead of raising is
-- intentional: raising here would roll back the failed-attempt counter
-- update below along with it, since Postgres unwinds everything done since
-- the start of an exception-catching block when an exception propagates —
-- including work done inside this function before the RAISE.
create or replace function verify_pin(p_name text, p_pin text)
returns uuid
language plpgsql
security definer
as $$
declare
  v_account accounts;
  v_lookup  pin_lookup;
begin
  select * into v_account from accounts
    where lower(name) = lower(p_name) and status = 'active'
    limit 1;

  if v_account.id is null then
    return null;
  end if;

  select * into v_lookup from pin_lookup where account_id = v_account.id;

  if v_lookup.locked_until is not null and v_lookup.locked_until > now() then
    return null;
  end if;

  if v_lookup.pin_hash is null or v_lookup.pin_hash <> crypt(p_pin, v_lookup.pin_hash) then
    update pin_lookup
      set failed_attempts = failed_attempts + 1,
          locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end,
          updated_at = now()
      where account_id = v_account.id;
    return null;
  end if;

  update pin_lookup set failed_attempts = 0, locked_until = null, updated_at = now()
    where account_id = v_account.id;

  return v_account.id;
end;
$$;

comment on function verify_pin is
  'Server-side only (service role). Returns account id on success, NULL on
   any failure. The caller (pin-login.js) still needs to mint a real Supabase
   session for accounts.user_id via the Admin API on success.';
