
-- Health Coach v1 foundation. Business writes are reserved for typed RPCs;
-- Android and Hermes never receive direct table DML privileges.

do $$
begin
  create role health_executor nologin nosuperuser nobypassrls nocreatedb nocreaterole noinherit;
exception when duplicate_object then null;
end
$$;

do $$
begin
  create role coach_executor nologin nosuperuser nobypassrls nocreatedb nocreaterole noinherit;
exception when duplicate_object then null;
end
$$;

do $$
begin
  create role integration_executor nologin nosuperuser nobypassrls nocreatedb nocreaterole noinherit;
exception when duplicate_object then null;
end
$$;

do $$
begin
  create role hermes_reader nologin nosuperuser nobypassrls nocreatedb nocreaterole inherit;
exception when duplicate_object then null;
end
$$;

create schema if not exists health;
create schema if not exists coach;
create schema if not exists integration;
create schema if not exists api;

revoke all on schema health, coach, integration, api from public, anon, authenticated;
grant usage on schema health, coach, integration to authenticated, hermes_reader,
  health_executor, coach_executor, integration_executor;
grant usage on schema api to authenticated, hermes_reader;

create table health.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  analysis_timezone text not null default 'America/Sao_Paulo',
  config_version bigint not null default 1 check (config_version > 0),
  source_policy_version integer not null default 1 check (source_policy_version > 0),
  mapping_version integer not null default 1 check (mapping_version > 0),
  hrv_enabled boolean not null default false,
  activities_enabled boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table health.metric_source_preferences (
  user_id uuid not null references auth.users(id) on delete cascade,
  data_type text not null check (data_type in (
    'steps', 'sleep_duration', 'resting_heart_rate', 'active_energy', 'total_energy',
    'distance', 'weight', 'hrv_rmssd', 'exercise_sessions'
  )),
  mode text not null check (mode in ('platform_aggregate', 'single_origin')),
  origin_package text,
  policy_version integer not null default 1 check (policy_version > 0),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, data_type),
  check (origin_package is null or length(origin_package) between 1 and 255),
  check (mode <> 'platform_aggregate' or (data_type in ('steps', 'active_energy', 'total_energy', 'distance') and origin_package is null))
);

create table health.sync_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active_installation_id uuid,
  source_scope_id uuid,
  writer_epoch bigint not null default 0 check (writer_epoch >= 0),
  data_revision bigint not null default 0 check (data_revision >= 0),
  lease_run_id uuid,
  lease_token uuid,
  lease_expires_at timestamptz,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_success_run_id uuid,
  last_completed_period_start date,
  last_completed_period_end date,
  updated_at timestamptz not null default clock_timestamp(),
  check ((lease_run_id is null) = (lease_token is null)),
  check ((lease_run_id is null) = (lease_expires_at is null)),
  check ((last_completed_period_start is null) = (last_completed_period_end is null)),
  check (last_completed_period_end is null or last_completed_period_end > last_completed_period_start)
);

create table health.sync_runs (
  run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  installation_id uuid not null,
  source_scope_id uuid not null,
  writer_epoch bigint not null check (writer_epoch > 0),
  config_version bigint not null check (config_version > 0),
  source_policy_version integer not null check (source_policy_version > 0),
  mapping_version integer not null check (mapping_version > 0),
  expected_data_types text[] not null,
  trigger text not null check (trigger in ('periodic', 'foreground', 'manual', 'backfill', 'audit')),
  requested_start date not null,
  requested_end date not null,
  analysis_timezone text not null,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'success', 'partial', 'failed', 'blocked', 'cancelled')),
  terminal_reason text,
  finish_payload_hash text,
  error_stage text,
  error_code text,
  committed_batches integer not null default 0 check (committed_batches >= 0),
  uploaded_items integer not null default 0 check (uploaded_items >= 0),
  changed_items integer not null default 0 check (changed_items >= 0),
  deleted_activities integer not null default 0 check (deleted_activities >= 0),
  contract_version integer not null default 1 check (contract_version = 1),
  last_lease_token uuid,
  last_lease_expires_at timestamptz,
  primary key (user_id, run_id),
  check (requested_end > requested_start),
  check ((status = 'running') = (finished_at is null))
);

alter table health.sync_state
  add constraint sync_state_last_success_run_fk
  foreign key (user_id, last_success_run_id)
  references health.sync_runs(user_id, run_id) on delete set null (last_success_run_id)
  deferrable initially deferred;
alter table health.sync_state
  add constraint sync_state_lease_run_fk
  foreign key (user_id, lease_run_id)
  references health.sync_runs(user_id, run_id) on delete set null (lease_run_id)
  deferrable initially deferred;

create table health.daily_metrics (
  user_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  metric text not null check (metric in (
    'steps', 'sleep_duration', 'resting_heart_rate', 'active_energy',
    'total_energy', 'distance', 'weight', 'hrv_rmssd'
  )),
  value numeric,
  unit text not null check (unit in ('count', 's', 'bpm', 'kcal', 'm', 'kg', 'ms')),
  availability text not null check (availability in ('available', 'no_data')),
  analysis_timezone text not null,
  period_start_at timestamptz not null,
  period_end_at timestamptz not null,
  observed_at timestamptz,
  read_at timestamptz,
  sample_count integer check (sample_count is null or sample_count >= 0),
  origins text[] not null default '{}',
  aggregation_method text not null,
  config_version bigint not null check (config_version > 0),
  source_policy_version integer not null check (source_policy_version > 0),
  mapping_version integer not null check (mapping_version > 0),
  source_scope_id uuid not null,
  writer_epoch bigint not null check (writer_epoch > 0),
  is_provisional boolean not null default false,
  quality_flags text[] not null default '{}',
  verification_state text not null default 'verified' check (verification_state in ('verified', 'unverified_history')),
  verification_reasons text[] not null default '{}',
  verification_changed_at timestamptz not null default clock_timestamp(),
  last_verified_at timestamptz,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  revision bigint not null check (revision >= 0),
  last_run_id uuid,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, local_date, metric),
  foreign key (user_id, last_run_id) references health.sync_runs(user_id, run_id) on delete set null (last_run_id) deferrable initially deferred,
  check (period_end_at > period_start_at),
  check ((availability = 'available') = (value is not null)),
  check (availability <> 'no_data' or (observed_at is null and cardinality(origins) = 0)),
  check (value is null or value >= 0 and value not in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
  check (metric <> 'weight' or value is null or value > 0),
  check (metric <> 'steps' or value is null or value = trunc(value)),
  check ((metric in ('steps') and unit = 'count') or
    (metric = 'sleep_duration' and unit = 's') or
    (metric = 'resting_heart_rate' and unit = 'bpm') or
    (metric in ('active_energy', 'total_energy') and unit = 'kcal') or
    (metric = 'distance' and unit = 'm') or
    (metric = 'weight' and unit = 'kg') or
    (metric = 'hrv_rmssd' and unit = 'ms')),
  check (verification_state <> 'verified' or cardinality(verification_reasons) = 0)
);

create table health.activity_day_states (
  user_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  availability text not null check (availability in ('available', 'no_data')),
  item_count integer not null check (item_count >= 0),
  analysis_timezone text not null,
  config_version bigint not null check (config_version > 0),
  mapping_version integer not null check (mapping_version > 0),
  source_policy_version integer not null check (source_policy_version > 0),
  source_scope_id uuid not null,
  writer_epoch bigint not null check (writer_epoch > 0),
  verification_state text not null default 'verified' check (verification_state in ('verified', 'unverified_history')),
  verification_reasons text[] not null default '{}',
  verification_changed_at timestamptz not null default clock_timestamp(),
  last_verified_at timestamptz,
  read_at timestamptz,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  revision bigint not null check (revision >= 0),
  last_run_id uuid,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, local_date),
  foreign key (user_id, last_run_id) references health.sync_runs(user_id, run_id) on delete set null (last_run_id) deferrable initially deferred,
  check ((availability = 'available') = (item_count > 0)),
  check (verification_state <> 'verified' or cardinality(verification_reasons) = 0)
);

create table health.activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  origin_package text not null,
  hc_record_id text not null,
  source_scope_id uuid not null,
  source_last_modified_at timestamptz,
  exercise_type integer not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  start_local_date date not null,
  analysis_timezone text not null,
  duration_seconds numeric not null check (duration_seconds > 0 and duration_seconds not in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
  writer_epoch bigint not null check (writer_epoch > 0),
  config_version bigint not null check (config_version > 0),
  source_policy_version integer not null check (source_policy_version > 0),
  mapping_version integer not null check (mapping_version > 0),
  verification_state text not null default 'verified' check (verification_state in ('verified', 'unverified_history')),
  verification_reasons text[] not null default '{}',
  verification_changed_at timestamptz not null default clock_timestamp(),
  last_verified_at timestamptz,
  revision bigint not null check (revision >= 0),
  last_run_id uuid,
  updated_at timestamptz not null default clock_timestamp(),
  unique (user_id, source_scope_id, hc_record_id),
  foreign key (user_id, start_local_date) references health.activity_day_states(user_id, local_date) deferrable initially deferred,
  foreign key (user_id, last_run_id) references health.sync_runs(user_id, run_id) on delete set null (last_run_id) deferrable initially deferred,
  check (end_at > start_at),
  check (verification_state <> 'verified' or cardinality(verification_reasons) = 0)
);
create index activities_user_date_idx on health.activities(user_id, start_local_date);
create index activities_user_start_idx on health.activities(user_id, start_at, id);

create table health.sync_metric_results (
  user_id uuid not null,
  run_id uuid not null,
  data_type text not null,
  requested_start date not null,
  requested_end date not null,
  completed_dates date[] not null default '{}',
  date_results jsonb not null default '[]'::jsonb check (jsonb_typeof(date_results) = 'array'),
  origins text[] not null default '{}',
  records_read integer check (records_read is null or records_read >= 0),
  items_committed integer not null default 0 check (items_committed >= 0),
  source_latest_observed_at timestamptz,
  background_feature_available boolean,
  background_permission_granted boolean,
  history_permission_granted boolean,
  error_stage text,
  error_code text,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, run_id, data_type),
  foreign key (user_id, run_id) references health.sync_runs(user_id, run_id) on delete cascade,
  check (requested_end > requested_start)
);

create table health.sync_batch_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  run_id uuid not null,
  source_scope_id uuid not null,
  writer_epoch bigint not null check (writer_epoch > 0),
  lease_token uuid not null,
  config_version bigint not null check (config_version > 0),
  base_revision bigint not null check (base_revision >= 0),
  committed_revision bigint not null check (committed_revision >= 0),
  accepted_items integer not null check (accepted_items >= 0),
  changed_items integer not null check (changed_items >= 0),
  deleted_activities integer not null default 0 check (deleted_activities >= 0),
  committed_at timestamptz not null default clock_timestamp(),
  primary key (user_id, batch_id),
  unique (user_id, batch_id, run_id),
  foreign key (user_id, run_id) references health.sync_runs(user_id, run_id) on delete cascade
);

create table health.sync_confirmed_targets (
  user_id uuid not null,
  run_id uuid not null,
  data_type text not null,
  local_date date not null,
  batch_id uuid not null,
  availability text not null check (availability in ('available', 'no_data')),
  read_at timestamptz not null,
  confirmed_at timestamptz not null default clock_timestamp(),
  primary key (user_id, run_id, data_type, local_date),
  foreign key (user_id, run_id) references health.sync_runs(user_id, run_id) on delete cascade,
  foreign key (user_id, batch_id, run_id) references health.sync_batch_receipts(user_id, batch_id, run_id) on delete cascade
);

create table integration.operation_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  operation_kind text not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  committed_at timestamptz not null default clock_timestamp(),
  primary key (user_id, operation_id)
);

create table coach.weekly_publications (
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null,
  active_generation_id uuid,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, period_start),
  check (extract(isodow from period_start) = 1)
);

create table coach.generator_versions (
  version text primary key check (length(version) between 1 and 64 and version ~ '^[A-Za-z0-9_.-]+$'),
  prompt_version text not null,
  model_identifier text not null,
  enabled boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);

create table coach.coach_generations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  analysis_timezone text not null,
  config_version bigint not null check (config_version > 0),
  input_revision bigint not null check (input_revision >= 0),
  input_fingerprint text not null check (input_fingerprint ~ '^[0-9a-f]{64}$'),
  generator_version text not null references coach.generator_versions(version),
  prompt_version text not null,
  model_identifier text not null,
  generation_key text not null,
  status text not null check (status in ('running', 'completed', 'failed', 'superseded')),
  claim_token uuid,
  claim_expires_at timestamptz,
  publication_hash text,
  publication_receipt jsonb,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  insight_count integer not null default 0 check (insight_count between 0 and 3),
  error_code text,
  unique (user_id, id),
  unique (user_id, period_start, period_end, generator_version, input_revision),
  unique (user_id, generation_key),
  check (period_end = period_start + 7 and extract(isodow from period_start) = 1),
  check (generation_key = 'weekly:v1:' || period_start::text || ':' || generator_version || ':' || input_revision::text),
  check ((claim_token is null) = (claim_expires_at is null)),
  check (publication_receipt is null or jsonb_typeof(publication_receipt) = 'object')
);

alter table coach.weekly_publications
  add constraint weekly_publication_generation_fk
  foreign key (user_id, active_generation_id)
  references coach.coach_generations(user_id, id) on delete set null (active_generation_id)
  deferrable initially deferred;

create table coach.coach_insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  generation_id uuid not null,
  slot smallint not null check (slot between 1 and 3),
  period_start date not null,
  period_end date not null,
  analysis_timezone text not null,
  type text not null check (type in ('trend', 'consistency', 'activity', 'data_quality')),
  title text not null check (length(title) between 1 and 120),
  body text not null check (length(body) between 1 and 2000),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'array' and jsonb_array_length(evidence) between 1 and 10),
  input_revision bigint not null check (input_revision >= 0),
  state text not null check (state in ('published', 'superseded', 'withdrawn')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (user_id, id),
  unique (user_id, generation_id, slot),
  foreign key (user_id, generation_id) references coach.coach_generations(user_id, id) on delete cascade,
  check (period_end = period_start + 7)
);
create index coach_insights_user_state_created_idx on coach.coach_insights(user_id, state, created_at desc, id);

create table coach.insight_user_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  insight_id uuid not null references coach.coach_insights(id) on delete cascade,
  read_at timestamptz,
  dismissed_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, insight_id),
  foreign key (user_id, insight_id) references coach.coach_insights(user_id, id) on delete cascade
);

create table integration.service_user_bindings (
  db_role text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null default true,
  created_at timestamptz not null default clock_timestamp()
);

create table integration.telegram_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telegram_user_id bigint not null unique,
  chat_id bigint not null unique,
  verified_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);

create table integration.telegram_link_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_telegram_user_id bigint,
  consumed_chat_id bigint,
  created_at timestamptz not null default clock_timestamp()
);

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

revoke all on function integration.current_user_id() from public, anon;
grant execute on function integration.current_user_id() to authenticated, hermes_reader,
  health_executor, coach_executor, integration_executor;

-- Every owner-scoped table uses the same identity resolver. This is defense in depth;
-- only the future typed API functions receive table DML grants.
do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'health.profiles', 'health.metric_source_preferences', 'health.sync_state',
    'health.sync_runs', 'health.daily_metrics', 'health.activity_day_states',
    'health.activities', 'health.sync_metric_results', 'health.sync_batch_receipts',
    'health.sync_confirmed_targets', 'integration.operation_receipts',
    'coach.weekly_publications', 'coach.coach_generations', 'coach.coach_insights',
    'coach.insight_user_state', 'integration.telegram_links',
    'integration.telegram_link_challenges'
  ] loop
    execute format('alter table %s enable row level security', table_name);
    execute format('alter table %s force row level security', table_name);
    execute format('create policy owner_isolation on %s for all to authenticated, hermes_reader, health_executor, coach_executor, integration_executor using (user_id = (select integration.current_user_id())) with check (user_id = (select integration.current_user_id()))', table_name);
  end loop;
end
$$;

alter table coach.generator_versions enable row level security;
alter table coach.generator_versions force row level security;
create policy generator_versions_read on coach.generator_versions
  for select to hermes_reader, coach_executor using (enabled or current_user = 'coach_executor');

alter table integration.service_user_bindings enable row level security;
alter table integration.service_user_bindings force row level security;
create policy binding_self_read on integration.service_user_bindings
  for select to hermes_reader using (db_role = session_user::text and enabled);
create policy binding_executor_read on integration.service_user_bindings
  for select to health_executor, coach_executor, integration_executor
  using (db_role = session_user::text and enabled);

-- Default deny direct writes. Typed SECURITY DEFINER RPCs will receive narrowly
-- scoped table privileges in the follow-up API migration.
revoke all on all tables in schema health, coach, integration from public, anon, authenticated, hermes_reader;
grant select on health.profiles, health.metric_source_preferences,
  health.daily_metrics, health.activity_day_states, health.activities
  to authenticated, hermes_reader, health_executor, coach_executor;
grant select on health.sync_state, health.sync_runs
  to authenticated, health_executor, coach_executor;
grant select (user_id, data_revision, last_attempt_at, last_success_at,
  last_success_run_id, last_completed_period_start, last_completed_period_end, updated_at)
  on health.sync_state to hermes_reader;
grant select (user_id, run_id, trigger, requested_start, requested_end, expected_data_types,
  analysis_timezone, started_at, finished_at, status, terminal_reason, error_stage,
  error_code, committed_batches, uploaded_items, changed_items, deleted_activities,
  contract_version) on health.sync_runs to hermes_reader;
grant select on health.sync_metric_results to hermes_reader;
grant select on coach.weekly_publications, coach.coach_generations, coach.coach_insights,
  coach.insight_user_state, coach.generator_versions to authenticated, hermes_reader, coach_executor;
grant select on coach.weekly_publications, coach.coach_generations, coach.coach_insights
  to health_executor;
grant select on integration.service_user_bindings to hermes_reader,
  health_executor, coach_executor, integration_executor;

grant select, insert, update on health.profiles, health.metric_source_preferences,
  health.sync_state, health.sync_runs, health.sync_metric_results,
  health.sync_batch_receipts, health.sync_confirmed_targets, integration.operation_receipts
  to health_executor;
grant select, insert, update, delete on health.daily_metrics, health.activities,
  health.activity_day_states to health_executor;
grant update (status, finished_at) on coach.coach_generations to health_executor;
grant update (state, updated_at) on coach.coach_insights to health_executor;
grant update (active_generation_id, updated_at) on coach.weekly_publications to health_executor;
grant select, insert on coach.coach_generations to coach_executor;
grant update (status, claim_token, claim_expires_at, publication_hash,
  publication_receipt, finished_at, insight_count, error_code)
  on coach.coach_generations to coach_executor;
grant select, insert on coach.weekly_publications to coach_executor;
grant update (active_generation_id, updated_at) on coach.weekly_publications to coach_executor;
grant insert on coach.coach_insights to coach_executor;
grant update (state, updated_at) on coach.coach_insights to coach_executor;
grant select, insert, update on integration.telegram_links,
  integration.telegram_link_challenges, integration.operation_receipts,
  coach.insight_user_state to integration_executor;
revoke all on all sequences in schema health, coach, integration from public, anon, authenticated, hermes_reader;

-- Do not expose the default public schema through PostgREST on this project.
alter role authenticator set pgrst.db_schemas = 'api';
notify pgrst, 'reload config';
