create or replace function health.assert_activity_day_count(p_user_id uuid, p_local_date date)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  stored_count integer;
  stored_availability text;
  actual_count bigint;
begin
  select state.item_count, state.availability
    into stored_count, stored_availability
    from health.activity_day_states as state
   where state.user_id = p_user_id and state.local_date = p_local_date;

  if not found then
    if exists (
      select 1 from health.activities as activity
       where activity.user_id = p_user_id and activity.start_local_date = p_local_date
    ) then
      raise exception 'activity_day_state_required' using errcode = '23514';
    end if;
    return;
  end if;

  select count(*) into actual_count
    from health.activities as activity
   where activity.user_id = p_user_id and activity.start_local_date = p_local_date;

  if actual_count <> stored_count
     or ((actual_count > 0) <> (stored_availability = 'available')) then
    raise exception 'activity_day_count_mismatch' using errcode = '23514';
  end if;
end;
$$;

create or replace function health.check_activity_day_count_trigger()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_table_name = 'activities' then
    if tg_op <> 'INSERT' then
      perform health.assert_activity_day_count(old.user_id, old.start_local_date);
    end if;
    if tg_op <> 'DELETE' and (
      tg_op = 'INSERT'
      or old.user_id is distinct from new.user_id
      or old.start_local_date is distinct from new.start_local_date
    ) then
      perform health.assert_activity_day_count(new.user_id, new.start_local_date);
    end if;
  else
    if tg_op <> 'DELETE' then
      perform health.assert_activity_day_count(new.user_id, new.local_date);
    end if;
    if tg_op <> 'INSERT' and (
      tg_op = 'DELETE'
      or old.user_id is distinct from new.user_id
      or old.local_date is distinct from new.local_date
    ) then
      perform health.assert_activity_day_count(old.user_id, old.local_date);
    end if;
  end if;
  return null;
end;
$$;

revoke all on function health.assert_activity_day_count(uuid, date) from public, anon, authenticated;
revoke all on function health.check_activity_day_count_trigger() from public, anon, authenticated;
grant execute on function health.assert_activity_day_count(uuid, date) to health_executor;
grant execute on function health.check_activity_day_count_trigger() to health_executor;

create constraint trigger activities_day_count_consistency
after insert or update or delete on health.activities
deferrable initially deferred
for each row execute function health.check_activity_day_count_trigger();

create constraint trigger activity_day_state_count_consistency
after insert or update or delete on health.activity_day_states
deferrable initially deferred
for each row execute function health.check_activity_day_count_trigger();
