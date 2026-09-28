-- Keep the V1 Data API limited to the two Android health tables.
-- This guard prevents removing business data added after the cleanup was prepared.
do $$
begin
  if exists (select 1 from api.insights) then
    raise exception 'V1 cleanup refused: api.insights contains data';
  end if;
  if exists (select 1 from integration.service_user_bindings) then
    raise exception 'V1 cleanup refused: integration.service_user_bindings contains data';
  end if;
  if exists (select 1 from api.activities) then
    raise exception 'V1 cleanup refused: api.activities contains data';
  end if;
end $$;

drop policy hermes_metrics_read on api.daily_metrics;
drop policy hermes_activities_read on api.activities;
drop table api.insights;
drop function integration.bound_user_id();
drop table integration.service_user_bindings;
drop schema integration;

alter table api.activities drop column analysis_timezone;
revoke delete on api.daily_metrics from authenticated;
revoke select on api.daily_metrics, api.activities from hermes_coach;
revoke usage on schema api from hermes_coach;
revoke usage on schema extensions from health_executor, coach_executor, integration_executor;

drop role hermes_coach, hermes_reader, health_executor, coach_executor,
  integration_executor, constraint_validator;

notify pgrst, 'reload schema';
