-- App Fit V1: Android writes its own Health Connect summaries through the Data API.
-- Keep this surface independent of the earlier health/coach/integration contracts.
create table api.daily_metrics (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  local_date date not null,
  metric text not null check (metric in (
    'steps', 'sleep_duration', 'resting_heart_rate', 'active_energy',
    'total_energy', 'distance', 'weight', 'hrv_rmssd'
  )),
  availability text not null check (availability in ('available', 'no_data')),
  value numeric check (value is null or (value >= 0 and value < 'Infinity'::numeric)),
  unit text not null check (length(btrim(unit)) > 0),
  analysis_timezone text not null check (length(btrim(analysis_timezone)) > 0),
  read_at timestamptz not null,
  is_provisional boolean not null default false,
  primary key (user_id, local_date, metric),
  check ((availability = 'available') = (value is not null))
);

create table api.activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  origin_package text not null check (length(btrim(origin_package)) > 0),
  hc_record_id text not null check (length(btrim(hc_record_id)) > 0),
  exercise_type integer not null check (exercise_type >= 0),
  start_at timestamptz not null,
  end_at timestamptz not null,
  local_date date not null,
  unique (user_id, origin_package, hc_record_id),
  check (end_at > start_at)
);

create index activities_user_date_start_idx
  on api.activities (user_id, local_date, start_at);

alter table api.daily_metrics enable row level security;
alter table api.activities enable row level security;

revoke all on table api.daily_metrics, api.activities from public, anon, authenticated;
grant select, insert, update on table api.daily_metrics to authenticated;
grant select, insert, update, delete on table api.activities to authenticated;

create policy daily_metrics_select_own on api.daily_metrics
  for select to authenticated
  using (user_id = (select auth.uid()));
create policy daily_metrics_insert_own on api.daily_metrics
  for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy daily_metrics_update_own on api.daily_metrics
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy activities_select_own on api.activities
  for select to authenticated
  using (user_id = (select auth.uid()));
create policy activities_insert_own on api.activities
  for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy activities_update_own on api.activities
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy activities_delete_own on api.activities
  for delete to authenticated
  using (user_id = (select auth.uid()));

notify pgrst, 'reload schema';
