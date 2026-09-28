-- Shared contract helpers; no DML grants to clients.
grant usage on schema auth, extensions to health_executor,coach_executor,integration_executor;
create function integration.require_identity_v1(p_channel text default 'either') returns uuid
language plpgsql stable security invoker set search_path='' as $$
declare u uuid;
begin
  u:=integration.current_user_id();
  if u is null or (p_channel='android' and session_user<>'authenticator')
    or (p_channel='hermes' and session_user='authenticator') then
    raise exception 'access_denied' using errcode='PT403';
  end if;
  return u;
end $$;
create function integration.check_keys_v1(j jsonb,required text[],optional text[] default '{}') returns void
language plpgsql immutable security invoker set search_path='' as $$
begin
  if j is null or jsonb_typeof(j)<>'object' or not j ?& required
    or exists(select 1 from jsonb_object_keys(j) k where not k=any(required||optional)) then
    raise exception 'invalid_contract' using errcode='PT422';
  end if;
end $$;
create function integration.jcs_v1(j jsonb) returns text language plpgsql immutable security invoker set search_path='' as $$
declare r text; n numeric;
begin
 case jsonb_typeof(j)
 when 'object' then
   if exists(select 1 from jsonb_object_keys(j) k where k !~ '^[ -~]+$') then raise exception 'invalid_contract' using errcode='PT422'; end if;
   select '{'||coalesce(string_agg(to_jsonb(k)::text||':'||integration.jcs_v1(v),',' order by k collate "C"),'')||'}'
     into r from jsonb_each(j) x(k,v);
 when 'array' then select '['||coalesce(string_agg(integration.jcs_v1(v),',' order by ord),'')||']' into r from jsonb_array_elements(j) with ordinality x(v,ord);
 when 'number' then
   n:=(j::text)::numeric;
   if abs(n)>9007199254740991 or (n<>0 and abs(n)<0.000001) then raise exception 'invalid_contract' using errcode='PT422'; end if;
   r:=n::text; if position('.' in r)>0 then r:=rtrim(rtrim(r,'0'),'.'); end if;
   if n=0 then r:='0'; end if;
 else r:=j::text;
 end case;
 return r;
end $$;
create function integration.hash_v1(j jsonb) returns text language sql immutable security invoker set search_path='' as $$
 select encode(extensions.digest(convert_to(integration.jcs_v1(j),'UTF8'),'sha256'),'hex')
$$;
create function integration.lock_owner_v1(u uuid) returns void language sql volatile security invoker set search_path='' as $$
 select pg_advisory_xact_lock(hashtextextended(u::text,26001))
$$;
create function health.context_v1() returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('installation_id',s.active_installation_id,'source_scope_id',s.source_scope_id,
 'writer_epoch',s.writer_epoch,'data_revision',s.data_revision,'lease_run_id',s.lease_run_id,
 'lease_token',s.lease_token,'lease_expires_at',s.lease_expires_at,
 'profile',to_jsonb(p)-array['user_id','created_at','updated_at'] ||
 jsonb_build_object('source_preferences',(select coalesce(jsonb_agg(to_jsonb(m)-array['user_id','updated_at'] order by data_type),'[]')
 from health.metric_source_preferences m where user_id=s.user_id)))
 from health.sync_state s join health.profiles p using(user_id)
 where s.user_id=integration.require_identity_v1('android')
$$;
create function health.get_sync_context_v1() returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('contract_version',1,'computed_at',statement_timestamp(),'replayed',false,
 'writer_registered',c is not null,'context',c) from (select health.context_v1() c) x
$$;
create function health.read_context_v1() returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare u uuid; r jsonb;
begin
 u:=integration.require_identity_v1();
 select jsonb_build_object('contract_version',1,'computed_at',statement_timestamp(),'replayed',false,
 'analysis_timezone',p.analysis_timezone,'config_version',p.config_version,'data_revision',s.data_revision) into r
 from health.profiles p join health.sync_state s using(user_id) where p.user_id=u;
 if r is null then raise exception 'profile_required' using errcode='PT409'; end if;
 return r;
end $$;
create function health.check_period_v1(a date,b date) returns void language plpgsql immutable security invoker set search_path='' as $$
begin if a is null or b is null or not isfinite(a) or not isfinite(b) or b<=a or b-a>90 then
 raise exception 'invalid_period' using errcode='PT422'; end if; end $$;
create function health.get_daily_metrics_v1(start_date date,end_date date) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare c jsonb; u uuid;
begin c:=health.read_context_v1(); u:=integration.require_identity_v1();
 perform health.check_period_v1(start_date,end_date);
 return c||jsonb_build_object('period_start',start_date,'period_end',end_date,'items',
 (select coalesce(jsonb_agg(to_jsonb(d)-'user_id' order by local_date,metric),'[]') from health.daily_metrics d
 where user_id=u and local_date>=start_date and local_date<end_date));
end $$;
create function health.metric_period_v1(m text,a date,b date) returns jsonb
language sql stable security invoker set search_path='' as $$
 with ctx as (select p.* from health.profiles p where user_id=integration.require_identity_v1()),
 dates as (select a+i d from generate_series(0,b-a-1) i),
 data as (select d.*, (d.verification_state='verified' and not d.is_provisional
   and d.config_version=p.config_version and d.analysis_timezone=p.analysis_timezone
   and d.source_policy_version=p.source_policy_version and d.mapping_version=p.mapping_version) compatible
   from health.daily_metrics d cross join ctx p where d.user_id=p.user_id and metric=m and local_date>=a and local_date<b),
 agg as (select count(*) filter(where compatible and availability='available')::integer n,
   count(*) filter(where compatible)::integer v, count(distinct aggregation_method) filter(where compatible and availability='available') methods,
   min(aggregation_method) filter(where compatible and availability='available') method,
   sum(value) filter(where compatible and availability='available') total,
   round(avg(value) filter(where compatible and availability='available'),3) mean,
   min(observed_at) filter(where compatible and availability='available') first_at,
   max(observed_at) filter(where compatible and availability='available') last_at,
   min(unit) unit from data)
 select jsonb_build_object('period_start',a,'period_end',b,'value',
   case when m='weight' then (select value from data where compatible and availability='available' order by local_date desc limit 1)
   when m in ('steps','active_energy','total_energy','distance') then total else mean end,
   'unit',coalesce(unit,case m when 'steps' then 'count' when 'sleep_duration' then 's' when 'resting_heart_rate' then 'bpm'
     when 'weight' then 'kg' when 'distance' then 'm' when 'hrv_rmssd' then 'ms' else 'kcal' end),
   'aggregation_method',method,'method_count',methods,'daily_average',mean,'average_value',mean,
   'last_measurement_date',(select max(local_date) from data where compatible and availability='available'),
   'available_days',n,'verified_days',v,'expected_days',b-a,'coverage_ratio',round(n::numeric/(b-a),6),
   'first_observed_at',first_at,'last_observed_at',last_at,
   'missing_dates',(select coalesce(jsonb_agg(d order by d),'[]') from dates where not exists(select 1 from data where local_date=d and availability='available')),
   'unverified_dates',(select coalesce(jsonb_agg(local_date order by local_date),'[]') from data where not compatible))
 from agg
$$;
create function health.get_period_summary_v1(end_date date default null,days integer default 7) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare c jsonb; u uuid; p health.profiles; e date; m text; x jsonb; y jsonb; items jsonb:='[]'; comparable boolean; xv numeric; yv numeric;
begin
 c:=health.read_context_v1(); u:=integration.require_identity_v1(); select * into p from health.profiles where user_id=u;
 if days is null or days not in(7,30,90) then raise exception 'invalid_period' using errcode='PT422'; end if;
 e:=coalesce(end_date,(statement_timestamp() at time zone p.analysis_timezone)::date);
 if not isfinite(e) or e>(statement_timestamp() at time zone p.analysis_timezone)::date then raise exception 'invalid_period' using errcode='PT422'; end if;
 foreach m in array array['steps','sleep_duration','resting_heart_rate','active_energy','total_energy','distance','weight','hrv_rmssd'] loop
  if m='hrv_rmssd' and not p.hrv_enabled then continue; end if;
  x:=health.metric_period_v1(m,e-days,e); y:=health.metric_period_v1(m,e-2*days,e-days);
  comparable:=(x->>'method_count')::int=1 and (y->>'method_count')::int=1 and x->>'aggregation_method'=y->>'aggregation_method'
    and (case when m='weight' then (x->>'available_days')::int>0 and (y->>'available_days')::int>0
    when days=7 then (x->>'available_days')::int>=5 and (y->>'available_days')::int>=5
    else (x->>'coverage_ratio')::numeric>=0.7 and (y->>'coverage_ratio')::numeric>=0.7 end);
  xv:=(case when m in('steps','active_energy','total_energy','distance') then x->>'daily_average' else x->>'value' end)::numeric;
  yv:=(case when m in('steps','active_energy','total_energy','distance') then y->>'daily_average' else y->>'value' end)::numeric;
  items:=items||jsonb_build_array(jsonb_build_object('metric',m,'current',x,'previous',y,'is_comparable',coalesce(comparable,false),
   'comparison_reasons',case when comparable then '[]'::jsonb else '["insufficient_or_incompatible_data"]'::jsonb end,
   'delta_absolute',case when comparable then round(xv-yv,3) end,
   'delta_percent',case when comparable and yv<>0 then round(100*(xv-yv)/yv,6) end));
 end loop;
 if p.activities_enabled then
  select jsonb_build_object('period_start',e-days,'period_end',e,'value',case when count(*)>0 then sum(item_count) end,
   'unit','count','aggregation_method','activity_day_count_v1','coverage_days',count(*),'expected_days',days) into x
   from health.activity_day_states where user_id=u and local_date>=e-days and local_date<e and verification_state='verified'
    and config_version=p.config_version and analysis_timezone=p.analysis_timezone;
  select jsonb_build_object('period_start',e-2*days,'period_end',e-days,'value',case when count(*)>0 then sum(item_count) end,
   'unit','count','aggregation_method','activity_day_count_v1','coverage_days',count(*),'expected_days',days) into y
   from health.activity_day_states where user_id=u and local_date>=e-2*days and local_date<e-days and verification_state='verified'
    and config_version=p.config_version and analysis_timezone=p.analysis_timezone;
  comparable:=(x->>'coverage_days')::int>=ceil(days*case when days=7 then 5.0/7 else 0.7 end)
   and (y->>'coverage_days')::int>=ceil(days*case when days=7 then 5.0/7 else 0.7 end);
  items:=items||jsonb_build_array(jsonb_build_object('metric','exercise_sessions','current',x,'previous',y,
    'is_comparable',comparable,'delta_absolute',case when comparable then (x->>'value')::numeric-(y->>'value')::numeric end,
    'delta_percent',case when comparable and (y->>'value')::numeric<>0 then round(100*((x->>'value')::numeric-(y->>'value')::numeric)/(y->>'value')::numeric,6) end,
    'comparison_reasons',case when comparable then '[]'::jsonb else '["insufficient_coverage"]'::jsonb end));
 end if;
 return c||jsonb_build_object('period_start',e-days,'period_end',e,'metrics',items);
end $$;
create function health.get_health_trends_v1(metric text,days integer default 7,end_date date default null) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare s jsonb; e date; r jsonb;
begin
 s:=health.get_period_summary_v1(end_date,days); e:=(s->>'period_end')::date;
 select v into r from jsonb_array_elements(s->'metrics') v where v->>'metric'=metric;
 if r is null then raise exception 'invalid_metric' using errcode='PT422'; end if;
 return s-'metrics'||jsonb_build_object('summary',r,'current_series',health.get_daily_metrics_v1(e-days,e)->'items',
 'previous_series',health.get_daily_metrics_v1(e-2*days,e-days)->'items');
end $$;
create function health.decode_cursor_v1(cursor text,filters jsonb,c jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare r jsonb;
begin
 if cursor is null then return null; end if;
 begin r:=convert_from(decode(translate(cursor,'-_','+/')||repeat('=',(4-length(cursor)%4)%4),'base64'),'UTF8')::jsonb;
 exception when others then raise exception 'cursor_conflict' using errcode='PT409'; end;
 if r->'filters' is distinct from filters or r->'config_version' is distinct from c->'config_version'
  or r->'data_revision' is distinct from c->'data_revision' then raise exception 'cursor_conflict' using errcode='PT409'; end if;
 return r;
end $$;
create function health.encode_cursor_v1(k jsonb,filters jsonb,c jsonb) returns text language sql immutable security invoker set search_path='' as $$
 select rtrim(translate(replace(encode(convert_to((k||jsonb_build_object('filters',filters,'config_version',c->'config_version',
 'data_revision',c->'data_revision'))::text,'UTF8'),'base64'),chr(10),''),'+/','-_'),'=')
$$;
create function health.get_activities_v1(start_date date,end_date date,cursor text default null,"limit" integer default 20) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare c jsonb; u uuid; cur jsonb; f jsonb; items jsonb; lastrow jsonb; cnt bigint;
begin
 c:=health.read_context_v1();u:=integration.require_identity_v1();perform health.check_period_v1(start_date,end_date);
 if "limit" is null or "limit" not between 1 and 100 then raise exception 'invalid_limit' using errcode='PT422'; end if;
 f:=jsonb_build_object('kind','activities','start_date',start_date,'end_date',end_date);
 cur:=health.decode_cursor_v1(cursor,f,c);
 select coalesce(jsonb_agg(to_jsonb(a)-'user_id' order by start_at,id),'[]'),count(*) into items,cnt from
 (select * from health.activities where user_id=u and start_local_date>=start_date and start_local_date<end_date
   and (cur is null or (start_at,id)>((cur->>'at')::timestamptz,(cur->>'id')::uuid))
  order by start_at,id limit "limit"+1) a;
 if cnt>"limit" then items:=items-"limit"; lastrow:=items->("limit"-1); end if;
 return c||jsonb_build_object('items',items,'day_states',(select coalesce(jsonb_agg(to_jsonb(d)-'user_id' order by local_date),'[]')
 from health.activity_day_states d where user_id=u and local_date>=start_date and local_date<end_date),
 'next_cursor',case when cnt>"limit" then health.encode_cursor_v1(jsonb_build_object('at',lastrow->'start_at','id',lastrow->'id'),f,c) end);
end $$;
create function coach.get_coach_insights_v1(start_date date,end_date date,cursor text default null,"limit" integer default 20) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare c jsonb;u uuid;cur jsonb;f jsonb;items jsonb;lr jsonb;n bigint;unread bigint;
begin
 c:=health.read_context_v1();u:=integration.require_identity_v1('android');perform health.check_period_v1(start_date,end_date);
 if "limit" is null or "limit" not between 1 and 100 then raise exception 'invalid_limit' using errcode='PT422'; end if;
 f:=jsonb_build_object('kind','insights','start_date',start_date,'end_date',end_date);cur:=health.decode_cursor_v1(cursor,f,c);
 select coalesce(jsonb_agg(to_jsonb(i)-'user_id' order by created_at desc,id desc),'[]'),count(*) into items,n from
 (select * from coach.coach_insights where user_id=u and state='published' and period_start<end_date and period_end>start_date
 and (cur is null or (created_at,id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid)) order by created_at desc,id desc limit "limit"+1) i;
 if n>"limit" then items:=items-"limit";lr:=items->("limit"-1);end if;
 select count(*) into unread from coach.coach_insights i left join coach.insight_user_state s on s.user_id=i.user_id and s.insight_id=i.id
 where i.user_id=u and i.state='published' and s.read_at is null and s.dismissed_at is null;
 return c||jsonb_build_object('items',items,'unread_count',unread,'next_cursor',case when n>"limit" then
 health.encode_cursor_v1(jsonb_build_object('at',lr->'created_at','id',lr->'id'),f,c) end);
end $$;
create function health.snapshot_hash_v1(d health.daily_metrics) returns text language sql immutable security invoker set search_path='' as $$
 select integration.hash_v1(jsonb_build_object('local_date',d.local_date,'metric',d.metric,'availability',d.availability,
 'value',d.value,'unit',d.unit,'period_start_at',to_char(d.period_start_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
 'period_end_at',to_char(d.period_end_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
 'observed_at',to_char(d.observed_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'origins',d.origins,'sample_count',d.sample_count,
 'aggregation_method',d.aggregation_method,'is_provisional',d.is_provisional,'quality_flags',d.quality_flags,
 'analysis_timezone',d.analysis_timezone,'config_version',d.config_version,'mapping_version',d.mapping_version,
 'source_policy_version',d.source_policy_version,'verification_state',d.verification_state,'verification_reasons',d.verification_reasons))
$$;
create function health.invalidate_coach_v1(u uuid,a date default null,b date default null) returns void
language plpgsql security invoker set search_path='' as $$
begin
 update coach.coach_insights i set state='superseded',updated_at=clock_timestamp()
 from coach.coach_generations g where i.user_id=u and g.user_id=u and i.generation_id=g.id and i.state='published'
  and (a is null or g.period_start-7<b and g.period_end>a);
 update coach.weekly_publications p set active_generation_id=null,updated_at=clock_timestamp()
 from coach.coach_generations g where p.user_id=u and g.user_id=u and p.active_generation_id=g.id
  and (a is null or g.period_start-7<b and g.period_end>a);
 update coach.coach_generations set status='superseded',finished_at=coalesce(finished_at,clock_timestamp())
 where user_id=u and status in('running','completed') and (a is null or period_start-7<b and period_end>a);
end $$;
create function health.degrade_v1(u uuid,types text[],a date,b date,reasons text[],rev bigint) returns integer
language plpgsql security invoker set search_path='' as $$
declare n integer:=0;k integer;
begin
 update health.daily_metrics d set verification_state='unverified_history',
 verification_reasons=(select array_agg(distinct r order by r) from unnest(d.verification_reasons||reasons) r),
 verification_changed_at=clock_timestamp(),revision=rev,updated_at=clock_timestamp()
 where user_id=u and (a is null or local_date>=a and local_date<b) and metric=any(types)
 and (verification_state<>'unverified_history' or not verification_reasons @> reasons);
 get diagnostics n=row_count;
 update health.daily_metrics d set content_hash=health.snapshot_hash_v1(d)
 where user_id=u and revision=rev;
 if 'exercise_sessions'=any(types) then
 update health.activity_day_states d set verification_state='unverified_history',
 verification_reasons=(select array_agg(distinct r order by r) from unnest(d.verification_reasons||reasons) r),
 verification_changed_at=clock_timestamp(),revision=rev,updated_at=clock_timestamp()
 where user_id=u and (a is null or local_date>=a and local_date<b)
 and (verification_state<>'unverified_history' or not verification_reasons @> reasons);
 get diagnostics k=row_count;n:=n+k;
 update health.activities x set verification_state=d.verification_state,verification_reasons=d.verification_reasons,
 verification_changed_at=d.verification_changed_at,revision=rev,updated_at=clock_timestamp()
 from health.activity_day_states d where x.user_id=u and d.user_id=u and x.start_local_date=d.local_date and d.revision=rev;
 get diagnostics k=row_count;n:=n+k;
 end if;return n;
end $$;
create function health.close_lease_v1(u uuid,reason text) returns void language plpgsql security invoker set search_path='' as $$
begin
 update health.sync_runs r set status=case when exists(select 1 from health.sync_confirmed_targets t where t.user_id=u and t.run_id=r.run_id)
 then 'partial' when reason='lease_expired' then 'failed' else 'blocked' end,
 terminal_reason=reason,finished_at=clock_timestamp()
 where r.user_id=u and r.status='running' and r.run_id=(select lease_run_id from health.sync_state where user_id=u);
 update health.sync_state set lease_run_id=null,lease_token=null,lease_expires_at=null where user_id=u;
end $$;
create function health.check_writer_v1(s health.sync_state,p health.profiles,j jsonb,config_key text default 'config_version') returns void
language plpgsql immutable security invoker set search_path='' as $$
begin
 if (j->>'installation_id')::uuid is distinct from s.active_installation_id
 or (j->>'writer_epoch')::bigint is distinct from s.writer_epoch
 or (j ? 'source_scope_id' and (j->>'source_scope_id')::uuid is distinct from s.source_scope_id) then
 raise exception 'writer_conflict' using errcode='PT409'; end if;
 if (j->>config_key)::bigint is distinct from p.config_version then raise exception 'config_conflict' using errcode='PT409';end if;
end $$;
create function health.check_lease_v1(s health.sync_state,j jsonb) returns void language plpgsql volatile security invoker set search_path='' as $$
begin if (j->>'run_id')::uuid is distinct from s.lease_run_id or (j->>'lease_token')::uuid is distinct from s.lease_token
 or s.lease_expires_at is null or s.lease_expires_at<=clock_timestamp() then
 raise exception 'lease_conflict' using errcode='PT409'; end if;end $$;
create function health.apply_operation_v1(kind text,j jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare u uuid;op uuid;h text;old integration.operation_receipts; s health.sync_state;p health.profiles;r health.sync_runs;
 now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());a date;b date;types text[]:=array['steps','sleep_duration','resting_heart_rate','active_energy','total_energy','distance','weight','hrv_rmssd','exercise_sessions'];
 x jsonb;y jsonb;outcome jsonb;changed integer:=0;policy_changed boolean;tz_changed boolean;run uuid;token uuid;cnt integer;expected integer;new_status text;
begin
 u:=integration.require_identity_v1('android');perform integration.lock_owner_v1(u);
 if kind='register_writer' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','installation_id','replace_current','reset_source_scope','expected_writer_epoch','expected_config_version','initial_timezone']);
 elsif kind='update_analysis_config' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','installation_id','writer_epoch','expected_config_version','analysis_timezone','source_preferences','hrv_enabled','activities_enabled']);
 elsif kind='begin_sync' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','run_id','installation_id','source_scope_id','writer_epoch','expected_config_version','trigger','period_start','period_end']);
 elsif kind='renew_sync_lease' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','run_id','installation_id','source_scope_id','writer_epoch','config_version','lease_token']);
 elsif kind='mark_history_unverified' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','run_id','installation_id','source_scope_id','writer_epoch','lease_token','config_version','base_revision','targets']);
 elsif kind='finish_sync' then
 perform integration.check_keys_v1(j,array['contract_version','operation_id','issued_at','run_id','installation_id','source_scope_id','writer_epoch','config_version','lease_token','termination','metric_results']);
 else raise exception 'invalid_contract' using errcode='PT422';end if;
 if j->'contract_version' is distinct from '1'::jsonb then raise exception 'invalid_contract' using errcode='PT422';end if;
 op:=(j->>'operation_id')::uuid;
 if op is null then raise exception 'invalid_contract' using errcode='PT422';end if;
 h:=integration.hash_v1(j);select * into old from integration.operation_receipts where user_id=u and operation_id=op;
 if found then
  if old.operation_kind<>kind or old.request_hash<>h then raise exception 'operation_conflict' using errcode='PT409';end if;
  return old.response||jsonb_build_object('replayed',true);
 end if;
 if (j->>'issued_at')::timestamptz is null or (j->>'issued_at')::timestamptz<now_at-interval '7 days'
 or (j->>'issued_at')::timestamptz>now_at+interval '5 minutes' then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into s from health.sync_state where user_id=u for update;
 select * into p from health.profiles where user_id=u;
 if kind='register_writer' then
  if (j->>'installation_id')::uuid is null or jsonb_typeof(j->'replace_current')<>'boolean' or jsonb_typeof(j->'reset_source_scope')<>'boolean' then
   raise exception 'invalid_contract' using errcode='PT422';end if;
  if p.user_id is null then
   if (j->>'expected_writer_epoch')::bigint is distinct from 0::bigint or (j->>'expected_config_version')::bigint is distinct from 0::bigint
   or j->'replace_current' is distinct from 'false'::jsonb or j->'reset_source_scope' is distinct from 'false'::jsonb
   or not exists(select 1 from pg_timezone_names where name=j->>'initial_timezone') then raise exception 'writer_conflict' using errcode='PT409';end if;
   insert into health.profiles(user_id,analysis_timezone) values(u,j->>'initial_timezone');
   insert into health.sync_state(user_id,active_installation_id,source_scope_id,writer_epoch) values(u,(j->>'installation_id')::uuid,gen_random_uuid(),1);
   insert into health.metric_source_preferences(user_id,data_type,mode) select u,t,case when t in('steps','active_energy','total_energy','distance') then 'platform_aggregate' else 'single_origin' end from unnest(types) t;
  else
   if j->'initial_timezone'<>'null'::jsonb or (j->>'expected_writer_epoch')::bigint is distinct from s.writer_epoch
   or (j->>'expected_config_version')::bigint is distinct from p.config_version then raise exception 'writer_conflict' using errcode='PT409';end if;
   if (j->>'installation_id')::uuid<>s.active_installation_id or (j->>'reset_source_scope')::boolean then
    if ((j->>'installation_id')::uuid<>s.active_installation_id and (j->'replace_current' is distinct from 'true'::jsonb or j->'reset_source_scope' is distinct from 'false'::jsonb))
    or ((j->>'installation_id')::uuid=s.active_installation_id and j->'replace_current' is distinct from 'false'::jsonb) then
     raise exception 'writer_conflict' using errcode='PT409';end if;
    perform health.close_lease_v1(u,'source_reset');
    changed:=health.degrade_v1(u,types,null,null,array['source_reset'],s.data_revision+1);
    perform health.invalidate_coach_v1(u);
    update health.sync_state set active_installation_id=(j->>'installation_id')::uuid,source_scope_id=gen_random_uuid(),
     writer_epoch=writer_epoch+1,data_revision=data_revision+case when changed>0 then 1 else 0 end,updated_at=now_at where user_id=u;
   end if;
  end if;
  outcome:=jsonb_build_object('writer_registered',true,'context',health.context_v1());
 else
  if p.user_id is null then raise exception 'profile_required' using errcode='PT409';end if;
  perform health.check_writer_v1(s,p,j,case when kind in('begin_sync','update_analysis_config') then 'expected_config_version' else 'config_version' end);
  if kind='update_analysis_config' then
   if not exists(select 1 from pg_timezone_names where name=j->>'analysis_timezone')
    or jsonb_typeof(j->'hrv_enabled') is distinct from 'boolean' or jsonb_typeof(j->'activities_enabled') is distinct from 'boolean'
    or jsonb_typeof(j->'source_preferences') is distinct from 'array' or jsonb_array_length(j->'source_preferences')<>9 then raise exception 'invalid_contract' using errcode='PT422';end if;
   if (select count(distinct v->>'data_type') from jsonb_array_elements(j->'source_preferences') v)<>9 then raise exception 'invalid_contract' using errcode='PT422';end if;
   for x in select * from jsonb_array_elements(j->'source_preferences') loop
    perform integration.check_keys_v1(x,array['data_type','mode','origin_package']);
    if not (x->>'data_type'=any(types)) or x->>'mode' not in('single_origin','platform_aggregate')
     or (x->>'mode'='platform_aggregate' and (x->>'data_type' not in('steps','active_energy','total_energy','distance') or x->'origin_package'<>'null'::jsonb))
     or (x->>'origin_package' is not null and length(x->>'origin_package') not between 1 and 255) then raise exception 'invalid_contract' using errcode='PT422';end if;
   end loop;
   policy_changed:=p.hrv_enabled<>(j->>'hrv_enabled')::boolean or p.activities_enabled<>(j->>'activities_enabled')::boolean
    or exists(select 1 from jsonb_array_elements(j->'source_preferences') v join health.metric_source_preferences m on m.user_id=u and m.data_type=v->>'data_type'
      where (m.mode,m.origin_package) is distinct from (v->>'mode',v->>'origin_package'));
   tz_changed:=p.analysis_timezone<>j->>'analysis_timezone';
   if policy_changed or tz_changed then
    perform health.close_lease_v1(u,'config_changed');
    changed:=health.degrade_v1(u,types,null,null,
     (case when tz_changed then array['timezone_changed'] else '{}'::text[] end)||(case when policy_changed then array['source_policy_changed'] else '{}'::text[] end),s.data_revision+1);
    update health.profiles set analysis_timezone=j->>'analysis_timezone',config_version=config_version+1,
      source_policy_version=source_policy_version+case when policy_changed then 1 else 0 end,
      hrv_enabled=(j->>'hrv_enabled')::boolean,activities_enabled=(j->>'activities_enabled')::boolean,updated_at=now_at where user_id=u;
    for x in select * from jsonb_array_elements(j->'source_preferences') loop
     update health.metric_source_preferences set mode=x->>'mode',origin_package=x->>'origin_package',policy_version=p.source_policy_version+1,updated_at=now_at
     where user_id=u and data_type=x->>'data_type' and (mode,origin_package) is distinct from (x->>'mode',x->>'origin_package');
    end loop;
    update health.sync_state set data_revision=data_revision+1,updated_at=now_at where user_id=u;
    perform health.invalidate_coach_v1(u);
   end if;
   outcome:=jsonb_build_object('context',health.context_v1(),'reprocess_required',policy_changed or tz_changed,
   'affected_data_types',case when policy_changed or tz_changed then to_jsonb(types) else '[]'::jsonb end);
  elsif kind='begin_sync' then
   a:=(j->>'period_start')::date;b:=(j->>'period_end')::date;perform health.check_period_v1(a,b);
   if a>(now_at at time zone p.analysis_timezone)::date or b>(now_at at time zone p.analysis_timezone)::date+1
    or j->>'trigger' not in('periodic','foreground','manual','backfill','audit') then raise exception 'invalid_contract' using errcode='PT422';end if;
   run:=(j->>'run_id')::uuid;if run is null then raise exception 'invalid_contract' using errcode='PT422';end if;
   select * into r from health.sync_runs where user_id=u and run_id=run;
   if r.user_id is not null and (r.status<>'running' or (r.installation_id,r.source_scope_id,r.writer_epoch,r.config_version,r.requested_start,r.requested_end,r.trigger)
     is distinct from(s.active_installation_id,s.source_scope_id,s.writer_epoch,p.config_version,a,b,j->>'trigger')) then raise exception 'run_closed' using errcode='PT409';end if;
   if s.lease_expires_at>now_at and s.lease_run_id<>run then raise exception 'lease_conflict' using errcode='PT409';end if;
   if s.lease_run_id<>run and s.lease_expires_at<=now_at then perform health.close_lease_v1(u,'lease_expired');end if;
   if r.user_id is null then
    types:=array['steps','sleep_duration','resting_heart_rate','active_energy','total_energy','distance','weight'];
    if p.hrv_enabled then types:=types||'hrv_rmssd';end if;if p.activities_enabled then types:=types||'exercise_sessions';end if;
    insert into health.sync_runs(user_id,run_id,installation_id,source_scope_id,writer_epoch,config_version,source_policy_version,mapping_version,expected_data_types,trigger,requested_start,requested_end,analysis_timezone)
    values(u,run,s.active_installation_id,s.source_scope_id,s.writer_epoch,p.config_version,p.source_policy_version,p.mapping_version,types,j->>'trigger',a,b,p.analysis_timezone);
   end if;
   token:=case when s.lease_run_id=run and s.lease_expires_at>now_at then s.lease_token else gen_random_uuid() end;
   update health.sync_state set lease_run_id=run,lease_token=token,lease_expires_at=case when s.lease_run_id=run and s.lease_expires_at>now_at then s.lease_expires_at else now_at+interval '15 minutes' end,
    last_attempt_at=now_at,updated_at=now_at where user_id=u;
   update health.sync_runs set last_lease_token=token,last_lease_expires_at=(select lease_expires_at from health.sync_state where user_id=u) where user_id=u and run_id=run;
   outcome:=jsonb_build_object('context',health.context_v1(),'run',(select to_jsonb(t)-'user_id' from health.sync_runs t where user_id=u and run_id=run),
    'confirmed_targets',(select coalesce(jsonb_agg(to_jsonb(t)-'user_id'),'[]') from health.sync_confirmed_targets t where user_id=u and run_id=run));
  elsif kind='renew_sync_lease' then
   perform health.check_lease_v1(s,j);
   update health.sync_state set lease_expires_at=now_at+interval '15 minutes',updated_at=now_at where user_id=u;
   update health.sync_runs set last_lease_expires_at=now_at+interval '15 minutes' where user_id=u and run_id=s.lease_run_id;
   outcome:=jsonb_build_object('context',health.context_v1(),'run_id',s.lease_run_id);
  elsif kind='mark_history_unverified' then
   perform health.check_lease_v1(s,j);
   if (j->>'base_revision')::bigint is distinct from s.data_revision then raise exception 'revision_conflict' using errcode='PT409';end if;
   if jsonb_typeof(j->'targets')<>'array' or jsonb_array_length(j->'targets')=0 or jsonb_array_length(j->'targets')>810 then raise exception 'invalid_contract' using errcode='PT422';end if;
   for x in select * from jsonb_array_elements(j->'targets') loop
    perform integration.check_keys_v1(x,array['data_type','period_start','period_end','reason']);a:=(x->>'period_start')::date;b:=(x->>'period_end')::date;perform health.check_period_v1(a,b);
    if not x->>'data_type'=any(types) or x->>'reason' not in('history_restricted','permission_denied','change_tracking_lost') then raise exception 'invalid_contract' using errcode='PT422';end if;
    changed:=changed+health.degrade_v1(u,array[x->>'data_type'],a,b,array[x->>'reason'],s.data_revision+1);
   end loop;
   if changed>0 then update health.sync_state set data_revision=data_revision+1,updated_at=now_at where user_id=u;perform health.invalidate_coach_v1(u);end if;
   outcome:=jsonb_build_object('committed_revision',s.data_revision+case when changed>0 then 1 else 0 end,'changed_targets',changed);
  elsif kind='finish_sync' then
   run:=(j->>'run_id')::uuid;select * into r from health.sync_runs where user_id=u and run_id=run;
   if r.run_id is null then raise exception 'not_found' using errcode='PT404';end if;
   if r.status<>'running' then
    if r.finish_payload_hash is not null and r.finish_payload_hash<>integration.hash_v1(j-'operation_id'-'issued_at') then raise exception 'finish_conflict' using errcode='PT409';end if;
   else
    if (j->>'lease_token')::uuid is distinct from r.last_lease_token then raise exception 'lease_conflict' using errcode='PT409';end if;
    if j->>'termination' not in('completed','user_cancelled','blocked','technical_failure') or jsonb_typeof(j->'metric_results')<>'array'
     or jsonb_array_length(j->'metric_results')<>cardinality(r.expected_data_types)
     or (select count(distinct v->>'data_type') from jsonb_array_elements(j->'metric_results') v)<>cardinality(r.expected_data_types) then raise exception 'invalid_contract' using errcode='PT422';end if;
    for x in select * from jsonb_array_elements(j->'metric_results') loop
     perform integration.check_keys_v1(x,array['data_type','date_results','origins','records_read','source_latest_observed_at','background_feature_available','background_permission_granted','history_permission_granted']);
     if not x->>'data_type'=any(r.expected_data_types) or jsonb_array_length(x->'date_results')<>r.requested_end-r.requested_start
      or (select count(distinct v->>'local_date') from jsonb_array_elements(x->'date_results') v)<>r.requested_end-r.requested_start then raise exception 'invalid_contract' using errcode='PT422';end if;
     for y in select * from jsonb_array_elements(x->'date_results') loop
      perform integration.check_keys_v1(y,array['local_date','availability','read_complete','upload_state','error_stage','error_code']);
      a:=(y->>'local_date')::date;
      if a<r.requested_start or a>=r.requested_end or y->>'availability' not in('available','no_data','permission_denied','history_restricted','unsupported','read_error','source_ambiguous')
       or y->>'upload_state' not in('confirmed','pending','failed','not_attempted') then raise exception 'invalid_contract' using errcode='PT422';end if;
      if exists(select 1 from health.sync_confirmed_targets t where user_id=u and run_id=run and data_type=x->>'data_type' and local_date=a) then
       if y->>'upload_state'<>'confirmed' or y->'read_complete' is distinct from 'true'::jsonb or not exists(select 1 from health.sync_confirmed_targets t
       where user_id=u and run_id=run and data_type=x->>'data_type' and local_date=a and availability=y->>'availability') then raise exception 'unconfirmed_target' using errcode='PT422';end if;
      elsif y->>'upload_state'='confirmed' then raise exception 'unconfirmed_target' using errcode='PT422';end if;
     end loop;
     insert into health.sync_metric_results(user_id,run_id,data_type,requested_start,requested_end,completed_dates,date_results,origins,records_read,items_committed,source_latest_observed_at,
       background_feature_available,background_permission_granted,history_permission_granted)
     values(u,run,x->>'data_type',r.requested_start,r.requested_end,
       (select coalesce(array_agg(local_date order by local_date),'{}') from health.sync_confirmed_targets where user_id=u and run_id=run and data_type=x->>'data_type'),
       x->'date_results',array(select jsonb_array_elements_text(x->'origins')),(x->>'records_read')::int,
       (select count(*) from health.sync_confirmed_targets where user_id=u and run_id=run and data_type=x->>'data_type'),(x->>'source_latest_observed_at')::timestamptz,
       (x->>'background_feature_available')::boolean,(x->>'background_permission_granted')::boolean,(x->>'history_permission_granted')::boolean);
    end loop;
    select count(*) into cnt from health.sync_confirmed_targets where user_id=u and run_id=run;
    expected:=cardinality(r.expected_data_types)*(r.requested_end-r.requested_start);
    new_status:=case when j->>'termination'='user_cancelled' then 'cancelled' when j->>'termination'='completed' and cnt=expected then 'success'
     when cnt>0 then 'partial' when j->>'termination'='blocked' or exists(select 1 from jsonb_array_elements(j->'metric_results') x,
       jsonb_array_elements(x->'date_results') y where y->>'availability' in('permission_denied','history_restricted','unsupported','source_ambiguous')) then 'blocked' else 'failed' end;
    update health.sync_runs set status=new_status,finished_at=now_at,terminal_reason=j->>'termination',finish_payload_hash=integration.hash_v1(j-'operation_id'-'issued_at') where user_id=u and run_id=run;
    if s.lease_run_id=run then update health.sync_state set lease_run_id=null,lease_token=null,lease_expires_at=null where user_id=u;end if;
    if new_status='success' then update health.sync_state set last_success_at=now_at,last_success_run_id=run,last_completed_period_start=r.requested_start,last_completed_period_end=r.requested_end,updated_at=now_at where user_id=u;end if;
   end if;
   outcome:=jsonb_build_object('run',(select to_jsonb(t)-'user_id' from health.sync_runs t where user_id=u and run_id=run),
    'last_success_at',(select last_success_at from health.sync_state where user_id=u),'last_success_run_id',(select last_success_run_id from health.sync_state where user_id=u));
  end if;
 end if;
 outcome:=outcome||jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false);
 insert into integration.operation_receipts(user_id,operation_id,operation_kind,request_hash,response) values(u,op,kind,h,outcome);
 return outcome;
exception when foreign_key_violation then raise exception 'access_denied' using errcode='PT403';
 when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range or check_violation or not_null_violation then raise exception 'invalid_contract' using errcode='PT422';
end $$;
create function integration.check_instant_v1(t text,nullable boolean default false) returns void
language plpgsql immutable security invoker set search_path='' as $$
begin if t is null and nullable then return;end if;
 if t is null or t !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$' or not isfinite(t::timestamptz) then
 raise exception 'invalid_contract' using errcode='PT422';end if;end $$;
create function health.receipt_json_v1(u uuid,b uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select to_jsonb(r)-array['user_id','base_revision']||jsonb_build_object('contract_version',1,'computed_at',r.committed_at,
 'confirmed_targets',(select coalesce(jsonb_agg(jsonb_build_object('data_type',t.data_type,'local_date',t.local_date,
 'availability',t.availability,'read_at',t.read_at,'confirmed_at',t.confirmed_at) order by local_date,data_type),'[]')
 from health.sync_confirmed_targets t where t.user_id=u and t.batch_id=b),'replayed',false)
 from health.sync_batch_receipts r where r.user_id=u and r.batch_id=b
$$;
create function health.commit_sync_batch_v1(envelope jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;s health.sync_state;p health.profiles;r health.sync_runs;receipt health.sync_batch_receipts;
 j jsonb:=envelope; x jsonb;y jsonb;z jsonb;d health.daily_metrics;prior health.daily_metrics;
 state health.activity_day_states;activity health.activities;prev health.activities;pref health.metric_source_preferences;
 batch uuid;h text;run uuid;a date;b date;dt date;dates date[];rev bigint;changed integer:=0;deleted integer:=0;accepted integer;
 now_at timestamptz:=date_trunc('milliseconds',clock_timestamp()); ch text;origins text[];flags text[];method text;n integer;k integer;
begin
 u:=integration.require_identity_v1('android');perform integration.lock_owner_v1(u);
 perform integration.check_keys_v1(j,array['contract_version','run_id','batch_id','installation_id','source_scope_id','writer_epoch','lease_token','base_revision','config_version',
 'analysis_timezone','source_policy_version','mapping_version','period_start','period_end','snapshots','activity_sets','payload_hash']);
 if j->'contract_version' is distinct from '1'::jsonb or jsonb_typeof(j->'snapshots')<>'array' or jsonb_typeof(j->'activity_sets')<>'array' then raise exception 'invalid_contract' using errcode='PT422';end if;
 h:=integration.hash_v1(j-'payload_hash');batch:=(j->>'batch_id')::uuid;run:=(j->>'run_id')::uuid;
 if batch is null or run is null or h is distinct from j->>'payload_hash' then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into receipt from health.sync_batch_receipts where user_id=u and batch_id=batch;
 if found then if receipt.payload_hash<>h then raise exception 'batch_conflict' using errcode='PT409';end if;return health.receipt_json_v1(u,batch)||'{"replayed":true}';end if;
 accepted:=jsonb_array_length(j->'snapshots')+jsonb_array_length(j->'activity_sets')+
 (select coalesce(sum(jsonb_array_length(v->'items')),0) from jsonb_array_elements(j->'activity_sets') v);
 if accepted<1 or accepted>500 or octet_length(j::text)>524288 then raise exception 'payload_limit_exceeded' using errcode='PT422';end if;
 select * into s from health.sync_state where user_id=u for update;select * into p from health.profiles where user_id=u;
 if p.user_id is null then raise exception 'profile_required' using errcode='PT409';end if;
 perform health.check_writer_v1(s,p,j);perform health.check_lease_v1(s,j);
 if (j->>'base_revision')::bigint is distinct from s.data_revision then raise exception 'revision_conflict' using errcode='PT409';end if;
 if (j->>'source_policy_version')::int is distinct from p.source_policy_version or (j->>'mapping_version')::int is distinct from p.mapping_version
 or j->>'analysis_timezone' is distinct from p.analysis_timezone then raise exception 'config_conflict' using errcode='PT409';end if;
 select * into r from health.sync_runs where user_id=u and run_id=run;
 if r.run_id is null or r.status<>'running' then raise exception 'run_closed' using errcode='PT409';end if;
 a:=(j->>'period_start')::date;b:=(j->>'period_end')::date;perform health.check_period_v1(a,b);
 if b-a>7 or a<r.requested_start or b>r.requested_end then raise exception 'invalid_contract' using errcode='PT422';end if;
 select array_agg(distinct dd) into dates from (
  select (v->>'local_date')::date dd from jsonb_array_elements(j->'snapshots') v union
  select (v->>'local_date')::date from jsonb_array_elements(j->'activity_sets') v) t;
 if cardinality(dates)>7 or exists(select 1 from unnest(dates) q where q<a or q>=b or q is null) then raise exception 'payload_limit_exceeded' using errcode='PT422';end if;
 if (select count(*) from jsonb_array_elements(j->'snapshots'))<>(select count(distinct (v->>'local_date',v->>'metric')) from jsonb_array_elements(j->'snapshots') v)
 or jsonb_array_length(j->'activity_sets')<>(select count(distinct v->>'local_date') from jsonb_array_elements(j->'activity_sets') v) then raise exception 'invalid_contract' using errcode='PT422';end if;
 rev:=s.data_revision+1;
 for x in select * from jsonb_array_elements(j->'snapshots') loop
  perform integration.check_keys_v1(x,array['local_date','metric','availability','value','unit','period_start_at','period_end_at','observed_at','read_at','origins','sample_count','aggregation_method','read_complete','is_provisional','quality_flags']);
  if x->'read_complete' is distinct from 'true'::jsonb or not x->>'metric'=any(r.expected_data_types)
   or x->>'metric'='exercise_sessions' or x->>'availability' not in('available','no_data') then raise exception 'invalid_contract' using errcode='PT422';end if;
  perform integration.check_instant_v1(x->>'read_at');perform integration.check_instant_v1(x->>'period_start_at');perform integration.check_instant_v1(x->>'period_end_at');perform integration.check_instant_v1(x->>'observed_at',true);
  if (x->>'read_at')::timestamptz<now_at-interval '7 days' or (x->>'read_at')::timestamptz>now_at+interval '5 minutes' then raise exception 'invalid_contract' using errcode='PT422';end if;
  d:=null;d.user_id:=u;d.local_date:=(x->>'local_date')::date;d.metric:=x->>'metric';d.value:=(x->>'value')::health.decimal_v1;d.unit:=x->>'unit';d.availability:=x->>'availability';
  if (d.availability='available' and jsonb_typeof(x->'value')<>'number') or (d.availability='no_data' and x->'value'<>'null'::jsonb) then raise exception 'invalid_contract' using errcode='PT422';end if;
  d.analysis_timezone:=p.analysis_timezone;d.period_start_at:=d.local_date::timestamp at time zone p.analysis_timezone;d.period_end_at:=(d.local_date+1)::timestamp at time zone p.analysis_timezone;
  if d.period_start_at is distinct from (x->>'period_start_at')::timestamptz or d.period_end_at is distinct from (x->>'period_end_at')::timestamptz then raise exception 'invalid_contract' using errcode='PT422';end if;
  d.observed_at:=(x->>'observed_at')::timestamptz;d.read_at:=(x->>'read_at')::timestamptz;d.sample_count:=(x->>'sample_count')::integer;
  if jsonb_typeof(x->'origins')<>'array' or jsonb_typeof(x->'quality_flags')<>'array' then raise exception 'invalid_contract' using errcode='PT422';end if;
  d.origins:=array(select jsonb_array_elements_text(x->'origins'));d.quality_flags:=array(select jsonb_array_elements_text(x->'quality_flags'));
  if d.origins is distinct from (select coalesce(array_agg(distinct v order by v collate "C"),'{}') from unnest(d.origins) v)
    or d.quality_flags is distinct from (select coalesce(array_agg(distinct v order by v collate "C"),'{}') from unnest(d.quality_flags) v)
    or exists(select 1 from unnest(d.quality_flags) v where v not in('session_duration_proxy','missing_stage_coverage'))
    or (d.metric<>'sleep_duration' and cardinality(d.quality_flags)>0) then raise exception 'invalid_contract' using errcode='PT422';end if;
  select * into pref from health.metric_source_preferences where user_id=u and data_type=d.metric;
  method:=case when pref.mode='platform_aggregate' then 'hc_aggregate_total_v1' when d.metric='sleep_duration' then 'sleep_session_duration_v1'
    when d.metric='weight' then 'selected_origin_last_v1' when d.metric in('resting_heart_rate','hrv_rmssd') then 'selected_origin_mean_v1' else 'selected_origin_total_v1' end;
  if x->>'aggregation_method'<>method or (d.availability='available' and (cardinality(d.origins)=0 or
    pref.mode='single_origin' and (pref.origin_package is null or d.origins is distinct from array[pref.origin_package])))
    or (d.availability='no_data' and (d.observed_at is not null or cardinality(d.origins)<>0 or coalesce(d.sample_count,0)<>0)) then raise exception 'invalid_contract' using errcode='PT422';end if;
  d.aggregation_method:=method;d.config_version:=p.config_version;d.source_policy_version:=p.source_policy_version;d.mapping_version:=p.mapping_version;
  d.source_scope_id:=s.source_scope_id;d.writer_epoch:=s.writer_epoch;d.is_provisional:=(x->>'is_provisional')::boolean;
  if d.is_provisional is distinct from (d.local_date>=(d.read_at at time zone p.analysis_timezone)::date) then raise exception 'invalid_contract' using errcode='PT422';end if;
  d.verification_state:='verified';d.verification_reasons:='{}';d.verification_changed_at:=now_at;d.last_verified_at:=now_at;d.last_run_id:=run;d.updated_at:=now_at;
  d.content_hash:=health.snapshot_hash_v1(d);
  select * into prior from health.daily_metrics where user_id=u and local_date=d.local_date and metric=d.metric;
  if prior.content_hash is distinct from d.content_hash then changed:=changed+1;d.revision:=rev;else d.revision:=prior.revision;d.verification_changed_at:=prior.verification_changed_at;end if;
  insert into health.daily_metrics select d.* on conflict(user_id,local_date,metric) do update set
   value=excluded.value,availability=excluded.availability,analysis_timezone=excluded.analysis_timezone,period_start_at=excluded.period_start_at,period_end_at=excluded.period_end_at,
   observed_at=excluded.observed_at,read_at=excluded.read_at,sample_count=excluded.sample_count,origins=excluded.origins,aggregation_method=excluded.aggregation_method,
   config_version=excluded.config_version,source_policy_version=excluded.source_policy_version,mapping_version=excluded.mapping_version,
   source_scope_id=excluded.source_scope_id,writer_epoch=excluded.writer_epoch,is_provisional=excluded.is_provisional,quality_flags=excluded.quality_flags,
   verification_state=excluded.verification_state,verification_reasons=excluded.verification_reasons,verification_changed_at=excluded.verification_changed_at,
   last_verified_at=excluded.last_verified_at,content_hash=excluded.content_hash,revision=excluded.revision,last_run_id=excluded.last_run_id,updated_at=excluded.updated_at;
 end loop;
 if jsonb_array_length(j->'activity_sets')>0 then
  if not p.activities_enabled or not 'exercise_sessions'=any(r.expected_data_types) then raise exception 'invalid_contract' using errcode='PT422';end if;
  select * into pref from health.metric_source_preferences where user_id=u and data_type='exercise_sessions';
  if exists(select 1 from jsonb_array_elements(j->'activity_sets') st,jsonb_array_elements(st->'items') v
    group by v->>'hc_record_id' having count(*)>1) then raise exception 'invalid_contract' using errcode='PT422';end if;
  for x in select * from jsonb_array_elements(j->'activity_sets') loop
   perform integration.check_keys_v1(x,array['local_date','read_complete','read_at','items']);dt:=(x->>'local_date')::date;
   perform integration.check_instant_v1(x->>'read_at');
   if x->'read_complete' is distinct from 'true'::jsonb or jsonb_typeof(x->'items')<>'array'
   or (x->>'read_at')::timestamptz<now_at-interval '7 days' or (x->>'read_at')::timestamptz>now_at+interval '5 minutes' then raise exception 'invalid_contract' using errcode='PT422';end if;
   for y in select * from jsonb_array_elements(x->'items') loop
    perform integration.check_keys_v1(y,array['hc_record_id','origin_package','source_last_modified_at','exercise_type','start_at','end_at']);
    perform integration.check_instant_v1(y->>'start_at');perform integration.check_instant_v1(y->>'end_at');perform integration.check_instant_v1(y->>'source_last_modified_at',true);
    if length(y->>'hc_record_id') not between 1 and 256 or length(y->>'origin_package') not between 1 and 255
     or y->>'origin_package' is distinct from pref.origin_package or pref.origin_package is null
     or ((y->>'start_at')::timestamptz at time zone p.analysis_timezone)::date<>dt then raise exception 'invalid_contract' using errcode='PT422';end if;
    if exists(select 1 from health.activities q where q.user_id=u and q.source_scope_id=s.source_scope_id and q.hc_record_id=y->>'hc_record_id'
      and q.start_local_date<>dt and not exists(select 1 from jsonb_array_elements(j->'activity_sets') v where (v->>'local_date')::date=q.start_local_date)) then
      raise exception 'activity_move_requires_old_set' using errcode='PT422';end if;
   end loop;
  end loop;
  delete from health.activities q where q.user_id=u and q.start_local_date in(select (v->>'local_date')::date from jsonb_array_elements(j->'activity_sets') v)
   and (q.source_scope_id<>s.source_scope_id or not exists(select 1 from jsonb_array_elements(j->'activity_sets') st,jsonb_array_elements(st->'items') v where v->>'hc_record_id'=q.hc_record_id));
  get diagnostics deleted=row_count;
  for x in select * from jsonb_array_elements(j->'activity_sets') loop
   dt:=(x->>'local_date')::date;n:=jsonb_array_length(x->'items');
   ch:=integration.hash_v1((x-'read_at'-'read_complete')||jsonb_build_object('availability',case when n>0 then 'available' else 'no_data' end,
    'analysis_timezone',p.analysis_timezone,'config_version',p.config_version,'mapping_version',p.mapping_version,'source_policy_version',p.source_policy_version,
    'verification_state','verified','verification_reasons','[]'::jsonb));
   select * into state from health.activity_day_states where user_id=u and local_date=dt;
   if state.content_hash is distinct from ch then changed:=changed+1;end if;
   insert into health.activity_day_states(user_id,local_date,availability,item_count,analysis_timezone,config_version,mapping_version,source_policy_version,source_scope_id,writer_epoch,
    verification_state,verification_reasons,verification_changed_at,last_verified_at,read_at,content_hash,revision,last_run_id,updated_at)
   values(u,dt,case when n>0 then 'available' else 'no_data' end,n,p.analysis_timezone,p.config_version,p.mapping_version,p.source_policy_version,s.source_scope_id,s.writer_epoch,
    'verified','{}',case when state.content_hash=ch then state.verification_changed_at else now_at end,now_at,(x->>'read_at')::timestamptz,ch,
    case when state.content_hash=ch then state.revision else rev end,run,now_at)
   on conflict(user_id,local_date) do update set availability=excluded.availability,item_count=excluded.item_count,analysis_timezone=excluded.analysis_timezone,
    config_version=excluded.config_version,mapping_version=excluded.mapping_version,source_policy_version=excluded.source_policy_version,source_scope_id=excluded.source_scope_id,
    writer_epoch=excluded.writer_epoch,verification_state='verified',verification_reasons='{}',verification_changed_at=excluded.verification_changed_at,
    last_verified_at=now_at,read_at=excluded.read_at,content_hash=excluded.content_hash,revision=excluded.revision,last_run_id=run,updated_at=now_at;
   for y in select * from jsonb_array_elements(x->'items') loop
    select * into prev from health.activities where user_id=u and source_scope_id=s.source_scope_id and hc_record_id=y->>'hc_record_id';
    activity:=null;activity.id:=coalesce(prev.id,gen_random_uuid());activity.user_id:=u;activity.origin_package:=y->>'origin_package';activity.hc_record_id:=y->>'hc_record_id';
    activity.source_scope_id:=s.source_scope_id;activity.source_last_modified_at:=(y->>'source_last_modified_at')::timestamptz;
    activity.exercise_type:=(y->>'exercise_type')::int;activity.start_at:=(y->>'start_at')::timestamptz;activity.end_at:=(y->>'end_at')::timestamptz;
    activity.start_local_date:=dt;activity.analysis_timezone:=p.analysis_timezone;activity.duration_seconds:=extract(epoch from activity.end_at-activity.start_at)::health.decimal_v1;
    activity.writer_epoch:=s.writer_epoch;activity.config_version:=p.config_version;activity.source_policy_version:=p.source_policy_version;activity.mapping_version:=p.mapping_version;
    activity.verification_state:='verified';activity.verification_reasons:='{}';
    if (to_jsonb(activity)-array['verification_changed_at','last_verified_at','revision','last_run_id','updated_at'])
    is distinct from (to_jsonb(prev)-array['verification_changed_at','last_verified_at','revision','last_run_id','updated_at']) then
      changed:=changed+1;activity.revision:=rev;activity.verification_changed_at:=now_at;
    else activity.revision:=prev.revision;activity.verification_changed_at:=prev.verification_changed_at;end if;
    activity.last_verified_at:=now_at;activity.last_run_id:=run;activity.updated_at:=now_at;
    insert into health.activities select activity.* on conflict(user_id,source_scope_id,hc_record_id) do update set
     origin_package=excluded.origin_package,source_last_modified_at=excluded.source_last_modified_at,exercise_type=excluded.exercise_type,
     start_at=excluded.start_at,end_at=excluded.end_at,start_local_date=excluded.start_local_date,analysis_timezone=excluded.analysis_timezone,duration_seconds=excluded.duration_seconds,
     writer_epoch=excluded.writer_epoch,config_version=excluded.config_version,source_policy_version=excluded.source_policy_version,mapping_version=excluded.mapping_version,
     verification_state='verified',verification_reasons='{}',verification_changed_at=excluded.verification_changed_at,last_verified_at=now_at,
     revision=excluded.revision,last_run_id=run,updated_at=now_at;
   end loop;
  end loop;
 end if;
 if changed>0 or deleted>0 then
  update health.sync_state set data_revision=rev,updated_at=now_at where user_id=u;
  perform health.invalidate_coach_v1(u,a,b);
 else rev:=s.data_revision;end if;
 insert into health.sync_batch_receipts(user_id,batch_id,payload_hash,run_id,source_scope_id,writer_epoch,lease_token,config_version,base_revision,committed_revision,accepted_items,changed_items,deleted_activities,committed_at)
 values(u,batch,h,run,s.source_scope_id,s.writer_epoch,s.lease_token,p.config_version,s.data_revision,rev,accepted,changed,deleted,now_at);
 insert into health.sync_confirmed_targets(user_id,run_id,data_type,local_date,batch_id,availability,read_at,confirmed_at)
 select u,run,v->>'metric',(v->>'local_date')::date,batch,v->>'availability',(v->>'read_at')::timestamptz,now_at from jsonb_array_elements(j->'snapshots') v
 union all select u,run,'exercise_sessions',(v->>'local_date')::date,batch,case when jsonb_array_length(v->'items')>0 then 'available' else 'no_data' end,(v->>'read_at')::timestamptz,now_at from jsonb_array_elements(j->'activity_sets') v
 on conflict(user_id,run_id,data_type,local_date) do update set batch_id=excluded.batch_id,availability=excluded.availability,read_at=excluded.read_at,confirmed_at=excluded.confirmed_at;
 update health.sync_runs set committed_batches=committed_batches+1,uploaded_items=uploaded_items+accepted,changed_items=changed_items+changed,deleted_activities=deleted_activities+deleted where user_id=u and run_id=run;
 return health.receipt_json_v1(u,batch);
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range or check_violation or not_null_violation then raise exception 'invalid_contract' using errcode='PT422';
end $$;
-- Narrow executor grants and bind the sync writers to a non-login role.
grant integration_executor, health_executor, coach_executor to postgres with admin option;
grant execute on function integration.require_identity_v1(text),integration.check_keys_v1(jsonb,text[],text[]),
 integration.jcs_v1(jsonb),integration.hash_v1(jsonb),integration.lock_owner_v1(uuid),integration.check_instant_v1(text,boolean) to health_executor,coach_executor,integration_executor;
grant execute on function health.context_v1(),health.check_period_v1(date,date),health.check_writer_v1(health.sync_state,health.profiles,jsonb,text),
 health.check_lease_v1(health.sync_state,jsonb),health.snapshot_hash_v1(health.daily_metrics),
 health.invalidate_coach_v1(uuid,date,date),health.degrade_v1(uuid,text[],date,date,text[],bigint),health.close_lease_v1(uuid,text),
 health.receipt_json_v1(uuid,uuid) to health_executor;
grant select,insert,update on health.profiles,health.metric_source_preferences,health.sync_state,health.sync_runs,
 health.sync_metric_results,health.sync_batch_receipts,health.sync_confirmed_targets,integration.operation_receipts,
 health.daily_metrics,health.activity_day_states,health.activities to health_executor;
grant delete on health.activities to health_executor;
grant update(status,finished_at,terminal_reason,finish_payload_hash,committed_batches,uploaded_items,changed_items,deleted_activities,last_lease_token,last_lease_expires_at)
 on health.sync_runs to health_executor;
grant update(data_revision,active_installation_id,source_scope_id,writer_epoch,lease_run_id,lease_token,lease_expires_at,last_attempt_at,last_success_at,
 last_success_run_id,last_completed_period_start,last_completed_period_end,updated_at) on health.sync_state to health_executor;
grant update on health.profiles,health.metric_source_preferences to health_executor;
grant update on health.daily_metrics,health.activity_day_states,health.activities to health_executor;
grant update(state,updated_at) on coach.coach_insights to health_executor;
grant update(status,finished_at) on coach.coach_generations to health_executor;
grant update(active_generation_id,updated_at) on coach.weekly_publications to health_executor;
grant select,insert on coach.weekly_publications,coach.coach_generations to health_executor;
grant health_executor to postgres with admin option;
grant create on schema health to health_executor;
alter function health.commit_sync_batch_v1(jsonb) owner to health_executor;
revoke create on schema health from health_executor;
revoke create on schema integration from integration_executor;

create function health.register_writer_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('register_writer',request);
end $$;
create function health.update_config_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('update_analysis_config',request);end $$;
create function health.begin_sync_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('begin_sync',request);end $$;
create function health.renew_sync_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('renew_sync_lease',request);end $$;
create function health.mark_history_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('mark_history_unverified',request);end $$;
create function health.finish_sync_impl_v1(request jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 return health.apply_operation_v1('finish_sync',request);end $$;
grant create on schema health to health_executor;
alter function health.register_writer_impl_v1(jsonb) owner to health_executor;
alter function health.update_config_impl_v1(jsonb) owner to health_executor;
alter function health.begin_sync_impl_v1(jsonb) owner to health_executor;
alter function health.renew_sync_impl_v1(jsonb) owner to health_executor;
alter function health.mark_history_impl_v1(jsonb) owner to health_executor;
alter function health.finish_sync_impl_v1(jsonb) owner to health_executor;
revoke create on schema health from health_executor;

-- PostgREST contains only thin INVOKER wrappers; policy and argument checks remain in the private implementation.
create function api.get_sync_context_v1() returns jsonb language sql stable security invoker set search_path='' as $$select health.get_sync_context_v1()$$;
create function api.register_writer_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.register_writer_impl_v1(request)$$;
create function api.update_analysis_config_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.update_config_impl_v1(request)$$;
create function api.begin_sync_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.begin_sync_impl_v1(request)$$;
create function api.renew_sync_lease_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.renew_sync_impl_v1(request)$$;
create function api.commit_sync_batch_v1(envelope jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.commit_sync_batch_v1(envelope)$$;
create function api.mark_history_unverified_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.mark_history_impl_v1(request)$$;
create function api.finish_sync_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$select health.finish_sync_impl_v1(request)$$;
create function api.get_daily_metrics_v1(start_date date,end_date date) returns jsonb language sql stable security invoker set search_path='' as $$select health.get_daily_metrics_v1(start_date,end_date)$$;
create function api.get_period_summary_v1(end_date date default null,days integer default 7) returns jsonb language sql stable security invoker set search_path='' as $$select health.get_period_summary_v1(end_date,days)$$;
create function api.get_activities_v1(start_date date,end_date date,cursor text default null,"limit" integer default 20) returns jsonb language sql stable security invoker set search_path='' as $$select health.get_activities_v1(start_date,end_date,cursor,"limit")$$;
create function api.get_sync_receipt_v1(batch_id uuid,payload_hash text) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare u uuid;r jsonb;
begin u:=integration.require_identity_v1('android');select case when q.payload_hash=api.get_sync_receipt_v1.payload_hash then health.receipt_json_v1(u,batch_id) end into r
 from health.sync_batch_receipts q where q.user_id=u and q.batch_id=api.get_sync_receipt_v1.batch_id;
 return jsonb_build_object('contract_version',1,'computed_at',statement_timestamp(),'found',r is not null,'receipt',r,'replayed',false);end $$;
create function api.get_sync_run_v1(run_id uuid) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare u uuid;r jsonb;
begin u:=integration.require_identity_v1('android');
 select to_jsonb(x)-'user_id'||jsonb_build_object('lease_active',s.lease_expires_at>clock_timestamp(),
  'lease_expires_at',s.lease_expires_at,'confirmed_targets',(select coalesce(jsonb_agg(to_jsonb(t)-'user_id'),'[]') from health.sync_confirmed_targets t where t.user_id=u and t.run_id=x.run_id),
  'metric_results',(select coalesce(jsonb_agg(to_jsonb(m)-'user_id'),'[]') from health.sync_metric_results m where m.user_id=u and m.run_id=x.run_id))
 into r from health.sync_runs x join health.sync_state s using(user_id) where x.user_id=u and x.run_id=api.get_sync_run_v1.run_id;
 return jsonb_build_object('contract_version',1,'computed_at',statement_timestamp(),'found',r is not null,'run',r,'replayed',false);end $$;
create function api.list_sync_runs_v1(cursor text default null,"limit" integer default 20) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare u uuid;c jsonb;cur jsonb;rows jsonb;lastrow jsonb;n int;f jsonb:='{"kind":"runs"}';
begin c:=health.read_context_v1();u:=integration.require_identity_v1('android');
 if "limit" not between 1 and 100 then raise exception 'invalid_limit' using errcode='PT422';end if;cur:=health.decode_cursor_v1(cursor,f,c);
 select coalesce(jsonb_agg(to_jsonb(x)-'user_id' order by started_at desc,run_id desc),'[]'),count(*) into rows,n
 from(select * from health.sync_runs r where user_id=u and (cur is null or (started_at,run_id)<((cur->>'at')::timestamptz,(cur->>'id')::uuid))
 order by started_at desc,run_id desc limit "limit"+1)x;
 if n>"limit" then rows:=rows-"limit";lastrow:=rows->("limit"-1);end if;
 return c||jsonb_build_object('items',rows,'next_cursor',case when n>"limit" then health.encode_cursor_v1(jsonb_build_object('at',lastrow->'started_at','id',lastrow->'run_id'),f,c) end);end $$;
create function api.get_sync_diagnostics_v1() returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare c jsonb;u uuid;
begin c:=health.read_context_v1();u:=integration.require_identity_v1('android');
 return c||jsonb_build_object('context',health.context_v1(),'last_attempt_at',(select last_attempt_at from health.sync_state where user_id=u),
  'last_success_at',(select last_success_at from health.sync_state where user_id=u),'last_success_run_id',(select last_success_run_id from health.sync_state where user_id=u),
  'last_completed_period_start',(select last_completed_period_start from health.sync_state where user_id=u),
  'last_completed_period_end',(select last_completed_period_end from health.sync_state where user_id=u),
  'recent_runs',(select coalesce(jsonb_agg(to_jsonb(r)-'user_id' order by started_at desc),'[]') from
   (select * from health.sync_runs where user_id=u order by started_at desc limit 20)r),
  'coverage',(select coalesce(jsonb_agg(jsonb_build_object('data_type',m.metric,'availability',m.availability,
   'verification_state',m.verification_state,'local_date',m.local_date) order by m.local_date desc,m.metric),'[]')
   from (select * from health.daily_metrics where user_id=u order by local_date desc limit 90) m));
end $$;
create function api.get_coach_insights_v1(start_date date,end_date date,cursor text default null,"limit" integer default 20) returns jsonb language sql stable security invoker set search_path='' as $$select coach.get_coach_insights_v1(start_date,end_date,cursor,"limit")$$;
create function api.mark_insight_v1(insight_id uuid,action text) returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare u uuid; iid uuid;now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());r coach.coach_insights;st coach.insight_user_state;unread int;
begin u:=integration.require_identity_v1('android');if action not in('read','dismiss') then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into r from coach.coach_insights where id=api.mark_insight_v1.insight_id and user_id=u;
 if not found then raise exception 'not_found' using errcode='PT404';end if;
 insert into coach.insight_user_state(user_id,insight_id,read_at,dismissed_at,updated_at)
 values(u,r.id,case when action='read' then now_at end,case when action='dismiss' then now_at end,now_at)
 on conflict(user_id,insight_id) do update set read_at=coalesce(coach.insight_user_state.read_at,excluded.read_at),
 dismissed_at=coalesce(coach.insight_user_state.dismissed_at,excluded.dismissed_at),updated_at=now_at returning * into st;
 select count(*) into unread from coach.coach_insights i left join coach.insight_user_state s on s.user_id=i.user_id and s.insight_id=i.id
 where i.user_id=u and i.state='published' and s.read_at is null and s.dismissed_at is null;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false,'id',r.id,'read_at',st.read_at,'dismissed_at',st.dismissed_at,'unread_count',unread);
end $$;
revoke execute on all functions in schema api from public,anon;
grant execute on function api.get_sync_context_v1(),api.get_daily_metrics_v1(date,date),api.get_period_summary_v1(date,integer),
 api.get_activities_v1(date,date,text,integer),api.get_coach_insights_v1(date,date,text,integer),api.mark_insight_v1(uuid,text),
 api.register_writer_v1(jsonb),api.update_analysis_config_v1(jsonb),api.begin_sync_v1(jsonb),api.renew_sync_lease_v1(jsonb),
 api.commit_sync_batch_v1(jsonb),api.mark_history_unverified_v1(jsonb),api.finish_sync_v1(jsonb),api.get_sync_receipt_v1(uuid,text),
 api.get_sync_run_v1(uuid),api.list_sync_runs_v1(text,integer),api.get_sync_diagnostics_v1() to authenticated;
grant execute on function api.get_period_summary_v1(date,integer),api.get_activities_v1(date,date,text,integer) to hermes_reader;
grant execute on function health.get_period_summary_v1(date,integer),health.get_health_trends_v1(text,integer,date),health.get_activities_v1(date,date,text,integer) to hermes_reader;
-- No direct SQL API to dispatch any arbitrary mutation.
revoke execute on all functions in schema integration from public,anon,authenticated,hermes_reader;
revoke execute on function health.apply_operation_v1(text,jsonb) from public,anon,authenticated,hermes_reader;
revoke execute on function health.commit_sync_batch_v1(jsonb),health.register_writer_impl_v1(jsonb),
 health.update_config_impl_v1(jsonb),health.begin_sync_impl_v1(jsonb),health.renew_sync_impl_v1(jsonb),
 health.mark_history_impl_v1(jsonb),health.finish_sync_impl_v1(jsonb) from public,anon,authenticated,hermes_reader;
grant execute on function health.commit_sync_batch_v1(jsonb),health.register_writer_impl_v1(jsonb),
 health.update_config_impl_v1(jsonb),health.begin_sync_impl_v1(jsonb),health.renew_sync_impl_v1(jsonb),
 health.mark_history_impl_v1(jsonb),health.finish_sync_impl_v1(jsonb) to authenticated;
grant execute on function health.get_sync_context_v1(),health.get_daily_metrics_v1(date,date),health.get_period_summary_v1(date,integer),
 health.get_activities_v1(date,date,text,integer),health.metric_period_v1(text,date,date),health.read_context_v1(),
 health.decode_cursor_v1(text,jsonb,jsonb),health.encode_cursor_v1(jsonb,jsonb,jsonb),
 integration.require_identity_v1(text),integration.check_keys_v1(jsonb,text[],text[]),integration.jcs_v1(jsonb),integration.hash_v1(jsonb)
 to authenticated,hermes_reader;
grant execute on function coach.get_coach_insights_v1(date,date,text,integer) to authenticated;
grant execute on function integration.require_identity_v1(text),integration.check_keys_v1(jsonb,text[],text[]),
 integration.jcs_v1(jsonb),integration.hash_v1(jsonb),integration.lock_owner_v1(uuid),integration.check_instant_v1(text,boolean),
 health.apply_operation_v1(text,jsonb) to health_executor;
