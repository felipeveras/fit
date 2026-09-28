-- Hermes needs sync coverage and revisions, but must not read Android lease tokens
-- or connection/source identifiers from the operational state tables.
revoke select on health.sync_state, health.sync_runs from hermes_reader;

grant select (user_id, data_revision, last_attempt_at, last_success_at,
  last_success_run_id, last_completed_period_start, last_completed_period_end, updated_at)
  on health.sync_state to hermes_reader;
grant select (user_id, run_id, trigger, requested_start, requested_end, expected_data_types,
  analysis_timezone, started_at, finished_at, status, terminal_reason, error_stage,
  error_code, committed_batches, uploaded_items, changed_items, deleted_activities,
  contract_version) on health.sync_runs to hermes_reader;
grant select on health.sync_metric_results to hermes_reader;
