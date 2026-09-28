-- HOM-26: one small, owner-scoped data model for the personal app.
-- The previous health/coach model has no business rows in the dedicated project.
-- Refuse to replace it if data was added after this migration was prepared.
do $$
declare item record; has_rows boolean;
begin
  for item in
    select schemaname, tablename from pg_tables
    where schemaname in ('api', 'health', 'coach', 'integration')
  loop
    execute format('select exists(select 1 from %I.%I)', item.schemaname, item.tablename)
      into has_rows;
    if has_rows then
      raise exception 'personal_model_requires_data_migration: %.%', item.schemaname, item.tablename;
    end if;
  end loop;
end $$;

drop schema if exists api cascade;
drop schema if exists health cascade;
drop schema if exists coach cascade;
drop schema if exists integration cascade;

create schema api;
create schema integration;
revoke all on schema api, integration from public, anon, authenticated;
grant usage on schema api to authenticated;

do $$
begin
  create role hermes_coach nologin nosuperuser nobypassrls nocreatedb nocreaterole inherit;
exception when duplicate_object then null;
end $$;
grant usage on schema api, integration to hermes_coach;

-- A Hermes login is bound by an administrator to exactly one Auth account.
create table integration.service_user_bindings (
  db_role name primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null default true
);
create unique index one_enabled_hermes_login_per_user
  on integration.service_user_bindings(user_id) where enabled;
alter table integration.service_user_bindings enable row level security;
alter table integration.service_user_bindings force row level security;
create policy executor_reads_own_binding on integration.service_user_bindings
  for select to hermes_coach
  using (enabled and db_role = session_user::name);
grant select on integration.service_user_bindings to hermes_coach;

create function integration.bound_user_id() returns uuid
language sql stable security invoker set search_path = '' as $$
  select b.user_id from integration.service_user_bindings b
  where b.db_role = session_user::name and b.enabled
$$;
revoke all on function integration.bound_user_id() from public, anon, authenticated;
grant execute on function integration.bound_user_id() to hermes_coach;

create table api.daily_metrics (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  local_date date not null,
  metric text not null check (metric in (
    'steps', 'sleep_duration', 'resting_heart_rate', 'active_energy',
    'total_energy', 'distance', 'weight', 'hrv_rmssd'
  )),
  availability text not null check (availability in ('available', 'no_data')),
  value numeric,
  unit text not null,
  analysis_timezone text not null check (length(btrim(analysis_timezone)) between 1 and 100),
  read_at timestamptz not null,
  is_provisional boolean not null default false,
  primary key (user_id, local_date, metric),
  check ((availability = 'available') = (value is not null)),
  check (value is null or (value >= 0 and value < 'Infinity'::numeric)),
  check (metric <> 'weight' or value is null or value > 0),
  check (metric <> 'steps' or value is null or value = trunc(value)),
  check (
    (metric = 'steps' and unit = 'count') or
    (metric = 'sleep_duration' and unit = 's') or
    (metric = 'resting_heart_rate' and unit = 'bpm') or
    (metric in ('active_energy', 'total_energy') and unit = 'kcal') or
    (metric = 'distance' and unit = 'm') or
    (metric = 'weight' and unit = 'kg') or
    (metric = 'hrv_rmssd' and unit = 'ms')
  )
);

create table api.activities (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  origin_package text not null check (length(btrim(origin_package)) between 1 and 255),
  hc_record_id text not null check (length(btrim(hc_record_id)) between 1 and 256),
  exercise_type integer not null check (exercise_type >= 0),
  start_at timestamptz not null,
  end_at timestamptz not null,
  local_date date not null,
  analysis_timezone text not null check (length(btrim(analysis_timezone)) between 1 and 100),
  primary key (user_id, origin_package, hc_record_id),
  check (end_at > start_at)
);
create index activities_user_day_start on api.activities(user_id, local_date, start_at);

-- Hermes writes the weekly text; Android can only read it.
create table api.insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null,
  slot smallint not null check (slot between 1 and 3),
  title text not null check (length(btrim(title)) between 1 and 120),
  body text not null check (length(btrim(body)) between 1 and 2000),
  evidence jsonb not null default '[]'::jsonb check (jsonb_typeof(evidence) = 'array'),
  created_at timestamptz not null default clock_timestamp(),
  unique (user_id, period_start, slot)
);
create index insights_user_week on api.insights(user_id, period_start desc);

alter table api.daily_metrics enable row level security;
alter table api.daily_metrics force row level security;
alter table api.activities enable row level security;
alter table api.activities force row level security;
alter table api.insights enable row level security;
alter table api.insights force row level security;

create policy owner_metrics on api.daily_metrics for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy hermes_metrics_read on api.daily_metrics for select to hermes_coach
  using (user_id = (select integration.bound_user_id()));
create policy owner_activities on api.activities for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy hermes_activities_read on api.activities for select to hermes_coach
  using (user_id = (select integration.bound_user_id()));
create policy owner_insights_read on api.insights for select to authenticated
  using (user_id = (select auth.uid()));
create policy hermes_insights on api.insights for all to hermes_coach
  using (user_id = (select integration.bound_user_id()))
  with check (user_id = (select integration.bound_user_id()));

revoke all on all tables in schema api, integration from public, anon, authenticated, hermes_coach;
grant select, insert, update, delete on api.daily_metrics, api.activities to authenticated;
grant select on api.insights to authenticated;
grant select on api.daily_metrics, api.activities to hermes_coach;
grant select, insert, update, delete on api.insights to hermes_coach;
notify pgrst, 'reload schema';
