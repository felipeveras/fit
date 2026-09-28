-- Cover foreign-key lookups that are not covered by a primary/unique index.
create index coach_generations_generator_version_idx
  on coach.coach_generations(generator_version);
create index insight_user_state_insight_idx
  on coach.insight_user_state(insight_id);
create index weekly_publications_active_generation_idx
  on coach.weekly_publications(user_id, active_generation_id);
create index activities_last_run_idx
  on health.activities(user_id, last_run_id);
create index activity_day_states_last_run_idx
  on health.activity_day_states(user_id, last_run_id);
create index daily_metrics_last_run_idx
  on health.daily_metrics(user_id, last_run_id);
create index sync_batch_receipts_run_idx
  on health.sync_batch_receipts(user_id, run_id);
create index sync_confirmed_targets_batch_idx
  on health.sync_confirmed_targets(user_id, batch_id, run_id);
create index sync_state_last_success_run_idx
  on health.sync_state(user_id, last_success_run_id);
create index sync_state_lease_run_idx
  on health.sync_state(user_id, lease_run_id);
create index service_user_bindings_user_idx
  on integration.service_user_bindings(user_id);
create index telegram_link_challenges_user_idx
  on integration.telegram_link_challenges(user_id);
