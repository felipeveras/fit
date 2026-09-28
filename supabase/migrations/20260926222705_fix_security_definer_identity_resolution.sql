-- SECURITY DEFINER changes current_user to the function owner. Resolve PostgREST
-- sessions from their gateway-verified JWT role and direct Hermes sessions from
-- the non-spoofable database session_user binding.
create or replace function integration.current_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when session_user = 'authenticator'
      and auth.jwt() ->> 'role' = 'authenticated'
      and coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'false'
      then auth.uid()
    when session_user not in ('postgres', 'service_role', 'supabase_admin', 'authenticator', 'anon', 'authenticated')
      then (
        select binding.user_id
        from integration.service_user_bindings as binding
        where binding.db_role = session_user::text
          and binding.enabled
      )
    else null
  end
$$;
