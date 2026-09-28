drop policy owner_isolation on coach.coach_insights;

create or replace function coach.is_active_publication(
  p_user_id uuid,
  p_generation_id uuid,
  p_period_start date
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    session_user = 'authenticator'
    and auth.jwt() ->> 'role' = 'authenticated'
    and coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'false'
    and auth.uid() = p_user_id
    and exists (
      select 1
        from coach.weekly_publications as publication
        join coach.coach_generations as generation
          on generation.user_id = publication.user_id
         and generation.id = publication.active_generation_id
       where publication.user_id = p_user_id
         and publication.period_start = p_period_start
         and publication.active_generation_id = p_generation_id
         and generation.status = 'completed'
    )
$$;

revoke all on function coach.is_active_publication(uuid, uuid, date) from public, anon;
grant execute on function coach.is_active_publication(uuid, uuid, date) to authenticated;

create policy android_active_insights_read on coach.coach_insights
  for select to authenticated
  using (
    user_id = (select auth.uid())
    and state = 'published'
    and (select coach.is_active_publication(user_id, generation_id, period_start))
  );

create policy server_roles_insights_read_write on coach.coach_insights
  for all to health_executor, coach_executor
  using (user_id = (select integration.current_user_id()))
  with check (user_id = (select integration.current_user_id()));

create policy hermes_own_insights_read on coach.coach_insights
  for select to hermes_reader
  using (user_id = (select integration.current_user_id()));

revoke select on coach.coach_generations from authenticated;
