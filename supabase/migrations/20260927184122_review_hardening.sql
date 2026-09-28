-- Draft promoted to a CLI-created migration after validation.
-- Never give an application membership in any executor/validator role.
do $$ begin
  create role constraint_validator nologin nosuperuser nobypassrls nocreatedb nocreaterole noinherit;
exception when duplicate_object then null; end $$;
grant integration_executor, coach_executor, constraint_validator to postgres;
grant usage on schema health, coach, integration to constraint_validator;
grant select on health.activities, health.activity_day_states,
  coach.weekly_publications, coach.coach_generations, coach.coach_insights,
  coach.generator_versions to constraint_validator;
do $$ declare t text; begin
  foreach t in array array['health.activities','health.activity_day_states',
    'coach.weekly_publications','coach.coach_generations','coach.coach_insights','coach.generator_versions'] loop
    execute format('create policy invariant_validation_read on %s for select to constraint_validator using (true)',t);
  end loop;
end $$;

-- Reading bindings needs RLS, not a postgres-owned definer.
grant create on schema integration to integration_executor;
alter function integration.current_user_id() owner to integration_executor;
revoke create on schema integration from integration_executor;
grant create on schema coach to coach_executor;
alter function coach.is_active_publication(uuid,uuid,date) owner to coach_executor;
revoke create on schema coach from coach_executor;
revoke select on coach.insight_user_state from hermes_reader;
-- Claims and publication receipts belong to the generation runtime, not readers.
revoke select on coach.coach_generations from hermes_reader;
grant select (id,user_id,period_start,period_end,analysis_timezone,config_version,
  input_revision,input_fingerprint,generator_version,prompt_version,model_identifier,
  generation_key,status,started_at,finished_at,insight_count,error_code)
  on coach.coach_generations to hermes_reader;

-- A numeric typmod silently rounds before CHECK/BEFORE triggers see the value.
-- A checked domain preserves the input and rejects precision loss instead.
create domain health.decimal_v1 as numeric
  check (value is null or (value not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
    and value between 0 and 999999999.999 and value = trunc(value,3)));
alter table health.daily_metrics alter column value type health.decimal_v1 using value::health.decimal_v1;
alter table health.activities alter column duration_seconds type health.decimal_v1 using duration_seconds::health.decimal_v1;
alter table health.activities add constraint activity_duration_matches_interval
  check (duration_seconds = extract(epoch from end_at-start_at));
alter table health.activities add constraint activity_date_matches_timezone
  check (start_local_date = (start_at at time zone analysis_timezone)::date);
alter table health.activities add constraint activity_type_nonnegative check (exercise_type >= 0);

create or replace function health.assert_activity_day_count(p_user_id uuid,p_local_date date)
returns void language plpgsql security invoker set search_path = '' as $$
declare s health.activity_day_states; n bigint;
begin
  select * into s from health.activity_day_states where user_id=p_user_id and local_date=p_local_date;
  select count(*) into n from health.activities where user_id=p_user_id and start_local_date=p_local_date;
  if s.user_id is null then
    if n<>0 then raise exception 'activity_day_state_required' using errcode='23514'; end if;
    return;
  end if;
  if n<>s.item_count or ((n>0)<>(s.availability='available')) then
    raise exception 'activity_day_count_mismatch' using errcode='23514';
  end if;
  if exists(select 1 from health.activities a where a.user_id=p_user_id and a.start_local_date=p_local_date
    and (a.analysis_timezone,a.config_version,a.source_policy_version,a.mapping_version,
      a.source_scope_id,a.writer_epoch,a.verification_state,a.verification_reasons)
    is distinct from (s.analysis_timezone,s.config_version,s.source_policy_version,s.mapping_version,
      s.source_scope_id,s.writer_epoch,s.verification_state,s.verification_reasons)) then
    raise exception 'activity_day_context_mismatch' using errcode='23514';
  end if;
end $$;
-- On PG17 the transaction's role at COMMIT differs from the definer that wrote.
-- The trigger has a fixed, read-only, non-admin owner and cannot be called as RPC.
alter function health.check_activity_day_count_trigger() security definer;
grant create on schema health to constraint_validator;
alter function health.check_activity_day_count_trigger() owner to constraint_validator;
revoke create on schema health from constraint_validator;
grant execute on function health.assert_activity_day_count(uuid,date) to constraint_validator;

create function coach.validate_weekly_publication_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
declare u uuid; g coach.coach_generations; p coach.weekly_publications; n bigint;
begin
  if tg_op='DELETE' then u:=old.user_id; else u:=new.user_id; end if;
  for p in select * from coach.weekly_publications where user_id=u and active_generation_id is not null loop
    select * into g from coach.coach_generations where user_id=u and id=p.active_generation_id;
    if g.id is null or g.period_start<>p.period_start or g.status<>'completed' then
      raise exception 'weekly_publication_generation_mismatch' using errcode='23514';
    end if;
  end loop;
  for g in select * from coach.coach_generations where user_id=u loop
    select count(*) into n from coach.coach_insights where user_id=u and generation_id=g.id;
    if n<>g.insight_count or n>3 then
      raise exception 'weekly_publication_count_mismatch' using errcode='23514';
    end if;
    if exists(select 1 from coach.coach_insights i where i.user_id=u and i.generation_id=g.id
      and (i.period_start,i.period_end,i.analysis_timezone,i.input_revision)
      is distinct from (g.period_start,g.period_end,g.analysis_timezone,g.input_revision)) then
      raise exception 'weekly_insight_context_mismatch' using errcode='23514';
    end if;
  end loop;
  if exists(select 1 from coach.coach_insights i where i.user_id=u and i.state='published'
    and not exists(select 1 from coach.weekly_publications p join coach.coach_generations g
      on g.id=p.active_generation_id and g.user_id=p.user_id
      where p.user_id=i.user_id and p.period_start=i.period_start
        and p.active_generation_id=i.generation_id and g.status='completed')) then
    raise exception 'published_insight_without_active_generation' using errcode='23514';
  end if;
  return null;
end $$;
grant create on schema coach to constraint_validator;
alter function coach.validate_weekly_publication_trigger() owner to constraint_validator;
revoke create on schema coach from constraint_validator;
revoke all on function coach.validate_weekly_publication_trigger() from public,anon,authenticated,hermes_reader;
create constraint trigger weekly_publication_consistency after insert or update or delete on coach.weekly_publications
  deferrable initially deferred for each row execute function coach.validate_weekly_publication_trigger();
create constraint trigger weekly_generation_consistency after insert or update or delete on coach.coach_generations
  deferrable initially deferred for each row execute function coach.validate_weekly_publication_trigger();
create constraint trigger weekly_insight_consistency after insert or update or delete on coach.coach_insights
  deferrable initially deferred for each row execute function coach.validate_weekly_publication_trigger();

create function coach.protect_published_content_trigger() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
  if tg_table_name='coach_insights' then
    if (to_jsonb(new)-array['state','updated_at']) is distinct from (to_jsonb(old)-array['state','updated_at']) then
      raise exception 'insight_content_immutable' using errcode='23514';
    end if;
    if old.state<>'published' and new.state='published' then
      raise exception 'insight_reactivation_forbidden' using errcode='23514';
    end if;
  elsif tg_table_name='coach_generations' then
    if (to_jsonb(new)-array['status','claim_token','claim_expires_at','publication_hash','publication_receipt','finished_at','insight_count','error_code'])
      is distinct from (to_jsonb(old)-array['status','claim_token','claim_expires_at','publication_hash','publication_receipt','finished_at','insight_count','error_code'])
      or (old.status in ('completed','superseded') and
        (new.publication_hash,new.publication_receipt,new.insight_count) is distinct from
        (old.publication_hash,old.publication_receipt,old.insight_count))
      or (old.status='superseded' and new.status<>'superseded') then
      raise exception 'generation_content_immutable' using errcode='23514';
    end if;
  elsif (new.version,new.prompt_version,new.model_identifier) is distinct from (old.version,old.prompt_version,old.model_identifier) then
    raise exception 'generator_version_immutable' using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function coach.protect_published_content_trigger() from public,anon,authenticated,hermes_reader;
create trigger immutable_insight before update on coach.coach_insights for each row execute function coach.protect_published_content_trigger();
create trigger immutable_generation before update on coach.coach_generations for each row execute function coach.protect_published_content_trigger();
create trigger immutable_generator_version before update on coach.generator_versions for each row execute function coach.protect_published_content_trigger();
revoke integration_executor, coach_executor, constraint_validator from postgres;
