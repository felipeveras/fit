-- Allow the SECURITY DEFINER identity resolver to call auth.jwt() and auth.uid().
grant usage on schema auth to integration_executor;
