

create function coach.weekly_input_v1(u uuid,p_start date) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p health.profiles; outv jsonb;
begin
 select * into p from health.profiles where user_id=u;
 select jsonb_build_object('profile',to_jsonb(p)-array['user_id','created_at','updated_at'],
  'preferences',(select coalesce(jsonb_agg(to_jsonb(m)-array['user_id','updated_at'] order by data_type),'[]')
   from health.metric_source_preferences m where user_id=u),
  'daily',(select coalesce(jsonb_agg(to_jsonb(d)-array['user_id','read_at','last_verified_at','verification_changed_at','updated_at','last_run_id']
    order by local_date,metric),'[]') from health.daily_metrics d where user_id=u
    and local_date>=p_start-7 and local_date<p_start+7
    and (d.metric<>'hrv_rmssd' or p.hrv_enabled)),
  'activity_days',(select coalesce(jsonb_agg(to_jsonb(d)-array['user_id','read_at','last_verified_at','verification_changed_at','updated_at','last_run_id']
    order by local_date),'[]') from health.activity_day_states d where user_id=u and p.activities_enabled
    and local_date>=p_start-7 and local_date<p_start+7),
  'activities',(select coalesce(jsonb_agg(to_jsonb(a)-array['user_id','last_verified_at','verification_changed_at','updated_at','last_run_id']
    order by start_local_date,start_at,hc_record_id),'[]') from health.activities a where user_id=u and p.activities_enabled
    and start_local_date>=p_start-7 and start_local_date<p_start+7))
 into outv;
 return outv;
end $$;
create function coach.expected_weekly_evidence_v1(u uuid,p_start date,p_revision bigint,j jsonb,p_summary jsonb) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare m text;stat text;currentj jsonb;previousj jsonb;valuej jsonb;comparison jsonb;result jsonb;
begin
 m:=j->>'metric';
 if not m=any(array['steps','sleep_duration','resting_heart_rate','active_energy','total_energy','distance','weight','hrv_rmssd','exercise_sessions'])
   or (m='hrv_rmssd' and not (select hrv_enabled from health.profiles where user_id=u))
   or (m='exercise_sessions' and not (select activities_enabled from health.profiles where user_id=u)) then
   raise exception 'invalid_evidence' using errcode='PT422';
 end if;
 select v into currentj from jsonb_array_elements(p_summary->'metrics') v where v->>'metric'=m;
 if m='exercise_sessions' then stat:='count';
 elsif m='weight' then stat:='last';
 elsif m in('steps','active_energy','total_energy','distance') then stat:=j->>'statistic';
 else stat:='mean';end if;
 if j->>'statistic' is distinct from stat or (stat not in('count','last','mean','total','daily_average')) then
  raise exception 'invalid_evidence' using errcode='PT422';end if;
 if m='exercise_sessions' then
  currentj:=jsonb_build_object('value',null,'unit','count','coverage_days',0,'expected_days',7,'aggregation_method','verified_activity_count_v1');
  select jsonb_build_object('value',sum(item_count),'unit','count','coverage_days',count(*),'expected_days',7,'aggregation_method','verified_activity_count_v1')
  into currentj from health.activity_day_states where user_id=u and local_date>=p_start and local_date<p_start+7
    and verification_state='verified' and analysis_timezone=(select analysis_timezone from health.profiles where user_id=u);
  currentj:=coalesce(currentj,jsonb_build_object('value',null,'unit','count','coverage_days',0,'expected_days',7,'aggregation_method','verified_activity_count_v1'));
  previousj:=null;
 else
  previousj:=currentj->'previous';
  currentj:=currentj->'current';
 end if;
 if stat='daily_average' then valuej:=currentj->'daily_average';
 elsif stat='total' then valuej:=currentj->'value';
 else valuej:=currentj->'value';end if;
 if j ? 'comparison' then
  if previousj is null then raise exception 'invalid_evidence' using errcode='PT422';end if;
  comparison:=jsonb_build_object('metric',m,'statistic',stat,'period_start',p_start-7,'period_end',p_start,
   'value',case when stat='daily_average' then previousj->'daily_average' else previousj->'value' end,
   'unit',currentj->'unit','coverage_days',previousj->'available_days','expected_days',7,'aggregation_method',previousj->'aggregation_method',
   'input_revision',p_revision);
 end if;
 result:=jsonb_build_object('metric',m,'statistic',stat,'period_start',p_start,'period_end',p_start+7,'value',valuej,
  'unit',currentj->'unit','coverage_days',coalesce(currentj->'available_days',currentj->'coverage_days'),'expected_days',7,
  'aggregation_method',coalesce(currentj->'aggregation_method','verified_activity_count_v1'),'input_revision',p_revision);
 if comparison is not null then result:=result||jsonb_build_object('comparison',comparison);end if;
 if j is distinct from result then raise exception 'invalid_evidence' using errcode='PT422';end if;
 return result;
end $$;
create function coach.begin_weekly_generation_v1(period_start date,generator_version text,input_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;p health.profiles;s health.sync_state;v coach.generator_versions;g coach.coach_generations;fp text;tok uuid;now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());
begin
 u:=integration.require_identity_v1('hermes');perform integration.lock_owner_v1(u);
 if period_start is null or extract(isodow from period_start)<>1 or period_start+7>(now_at at time zone (select analysis_timezone from health.profiles where user_id=u))::date
  or generator_version is null or length(generator_version) not between 1 and 64 or generator_version !~ '^[A-Za-z0-9_.-]+$'
  or input_revision is null or input_revision<0 then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into p from health.profiles where user_id=u;select * into s from health.sync_state where user_id=u for update;
 if p.user_id is null then raise exception 'profile_required' using errcode='PT409';end if;
 if s.data_revision<>input_revision then raise exception 'revision_conflict' using errcode='PT409';end if;
 select * into v from coach.generator_versions where version=generator_version and enabled;
 if v.version is null then raise exception 'generator_version_disabled' using errcode='PT409';end if;
 fp:=integration.hash_v1(coach.weekly_input_v1(u,period_start));
 select g0.* into g from coach.weekly_publications wp join coach.coach_generations g0
  on g0.user_id=wp.user_id and g0.id=wp.active_generation_id
 where wp.user_id=u and wp.period_start=begin_weekly_generation_v1.period_start and g0.generator_version=begin_weekly_generation_v1.generator_version
  and g0.input_fingerprint=fp and g0.status='completed';
 if found then return jsonb_build_object('contract_version',1,'computed_at',now_at,'disposition','already_current',
  'generation_id',g.id,'generation_key',g.generation_key,'input_fingerprint',fp,'input_revision',input_revision,
  'claim_token',null,'claim_expires_at',null);end if;
 select * into g from coach.coach_generations q where q.user_id=u and q.period_start=begin_weekly_generation_v1.period_start
  and q.generator_version=begin_weekly_generation_v1.generator_version and q.input_revision=begin_weekly_generation_v1.input_revision;
 if g.id is not null and g.status='superseded' then raise exception 'generation_superseded' using errcode='PT409';end if;
 if g.id is not null and g.status='running' and g.claim_expires_at>now_at then
  return jsonb_build_object('contract_version',1,'computed_at',now_at,'disposition','busy','generation_id',g.id,
   'generation_key',g.generation_key,'input_fingerprint',fp,'input_revision',input_revision,'claim_token',null,'claim_expires_at',null);end if;
 tok:=gen_random_uuid();
 if g.id is null then
  insert into coach.coach_generations(user_id,period_start,period_end,analysis_timezone,config_version,input_revision,input_fingerprint,
   generator_version,prompt_version,model_identifier,generation_key,status,claim_token,claim_expires_at)
  values(u,period_start,period_start+7,p.analysis_timezone,p.config_version,input_revision,fp,v.version,v.prompt_version,v.model_identifier,
   'weekly:v1:'||period_start::text||':'||v.version||':'||input_revision::text,'running',tok,now_at+interval '15 minutes') returning * into g;
 else
  update coach.coach_generations set status='running',claim_token=tok,claim_expires_at=now_at+interval '15 minutes',finished_at=null,error_code=null
   where id=g.id and user_id=u returning * into g;
 end if;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'disposition','generate','generation_id',g.id,'generation_key',g.generation_key,
  'input_fingerprint',fp,'input_revision',input_revision,'claim_token',tok,'claim_expires_at',g.claim_expires_at);
end $$;
create function coach.renew_generation_lease_v1(generation_id uuid,claim_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;g coach.coach_generations;e timestamptz:=date_trunc('milliseconds',clock_timestamp())+interval '15 minutes';
begin u:=integration.require_identity_v1('hermes');perform integration.lock_owner_v1(u);
 update coach.coach_generations set claim_expires_at=e where user_id=u and id=renew_generation_lease_v1.generation_id
  and status='running' and claim_token=renew_generation_lease_v1.claim_token and claim_expires_at>clock_timestamp() returning * into g;
 if g.id is null then raise exception 'claim_conflict' using errcode='PT409';end if;
 return jsonb_build_object('contract_version',1,'computed_at',clock_timestamp(),'generation_id',g.id,'claim_expires_at',e);
end $$;
create function coach.persist_weekly_insights_v1(generation_id uuid,claim_token uuid,input_revision bigint,insights jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;s health.sync_state;p health.profiles;g coach.coach_generations;wp coach.weekly_publications;v coach.generator_versions;
 now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());fp text;pubhash text;receipt jsonb;summary jsonb;x jsonb;e jsonb;prev coach.coach_generations;n integer:=0;slot_no integer:=0;
begin
 u:=integration.require_identity_v1('hermes');perform integration.lock_owner_v1(u);
 select * into g from coach.coach_generations where user_id=u and id=persist_weekly_insights_v1.generation_id for update;
 if g.id is null then raise exception 'not_found' using errcode='PT404';end if;
 if jsonb_typeof(insights)<>'array' or jsonb_array_length(insights)>3 then raise exception 'invalid_contract' using errcode='PT422';end if;
 pubhash:=integration.hash_v1(jsonb_build_object('generation_id',g.id,'input_revision',input_revision,'insights',insights));
 if g.status in('completed','superseded') then
  if g.publication_hash is distinct from pubhash then raise exception 'publication_conflict' using errcode='PT409';end if;
  return coalesce(g.publication_receipt,'{}')||jsonb_build_object('replayed',true,'contract_version',1,'computed_at',g.finished_at);
 end if;
 if g.status<>'running' or g.claim_token is distinct from persist_weekly_insights_v1.claim_token or g.claim_expires_at<=clock_timestamp()
  then raise exception 'claim_conflict' using errcode='PT409';end if;
 select * into s from health.sync_state where user_id=u for update;select * into p from health.profiles where user_id=u;
 if input_revision<>s.data_revision or input_revision<>g.input_revision then raise exception 'revision_conflict' using errcode='PT409';end if;
 fp:=integration.hash_v1(coach.weekly_input_v1(u,g.period_start));
 if fp<>g.input_fingerprint or not exists(select 1 from coach.generator_versions where version=g.generator_version and enabled
    and prompt_version=g.prompt_version and model_identifier=g.model_identifier) then raise exception 'input_conflict' using errcode='PT409';end if;
 summary:=health.get_period_summary_v1(g.period_end,7);
 for x in select * from jsonb_array_elements(insights) loop
  n:=n+1;perform integration.check_keys_v1(x,array['type','title','body','evidence']);
  if x->>'type' not in('trend','consistency','activity','data_quality') or length(x->>'title') not between 1 and 120 or length(x->>'body') not between 1 and 2000
   or jsonb_typeof(x->'evidence')<>'array' or jsonb_array_length(x->'evidence') not between 1 and 10 then raise exception 'invalid_contract' using errcode='PT422';end if;
  for e in select * from jsonb_array_elements(x->'evidence') loop
   perform integration.check_keys_v1(e,array['metric','statistic','period_start','period_end','value','unit','coverage_days','expected_days','aggregation_method','input_revision'],array['comparison']);
   perform coach.expected_weekly_evidence_v1(u,g.period_start,input_revision,e,summary);
   if x->>'type'='activity' and e->>'metric'<>'exercise_sessions' then raise exception 'invalid_evidence' using errcode='PT422';
   elsif x->>'type'<>'data_quality' then
    select z into prev from jsonb_array_elements(summary->'metrics') z where z->>'metric'=e->>'metric';
    if coalesce((prev->>'is_comparable')::boolean,false)=false then raise exception 'insufficient_evidence' using errcode='PT422';end if;
   elsif x->>'type'='data_quality' and coalesce(jsonb_array_length((select z->'current'->'missing_dates' from jsonb_array_elements(summary->'metrics') z where z->>'metric'=e->>'metric')),0)=0
     and (select z->'current'->'unverified_dates' from jsonb_array_elements(summary->'metrics') z where z->>'metric'=e->>'metric')='[]'::jsonb
     then raise exception 'invalid_evidence' using errcode='PT422';
   end if;
  end loop;
 end loop;
 select * into wp from coach.weekly_publications where user_id=u and period_start=g.period_start for update;
 if wp.active_generation_id is not null and wp.active_generation_id<>g.id then
  update coach.coach_insights set state='superseded',updated_at=now_at where user_id=u and generation_id=wp.active_generation_id and state='published';
  update coach.coach_generations set status='superseded',finished_at=coalesce(finished_at,now_at) where user_id=u and id=wp.active_generation_id;
 end if;
 update coach.coach_insights set state='superseded',updated_at=now_at where user_id=u and period_start=g.period_start and state='published' and generation_id<>g.id;
 for x in select value from jsonb_array_elements(insights) with ordinality q(value,ord) order by ord loop
  slot_no:=slot_no+1;
  insert into coach.coach_insights(user_id,generation_id,slot,period_start,period_end,analysis_timezone,type,title,body,evidence,input_revision,state)
   values(u,g.id,slot_no,g.period_start,g.period_end,g.analysis_timezone,x->>'type',x->>'title',x->>'body',x->'evidence',input_revision,'published');
 end loop;
 receipt:=jsonb_build_object('generation_id',g.id,'generation_key',g.generation_key,'input_revision',input_revision,
  'published_count',jsonb_array_length(insights),'insight_ids',(select coalesce(jsonb_agg(id order by slot),'[]') from coach.coach_insights where user_id=u and generation_id=g.id),
  'published_at',now_at,'replayed',false,'contract_version',1,'computed_at',now_at);
 update coach.coach_generations set status='completed',claim_token=null,claim_expires_at=null,publication_hash=pubhash,
 publication_receipt=receipt,finished_at=now_at,insight_count=jsonb_array_length(insights),error_code=null where user_id=u and id=g.id returning * into g;
 insert into coach.weekly_publications(user_id,period_start,active_generation_id,updated_at) values(u,g.period_start,g.id,now_at)
 on conflict(user_id,period_start) do update set active_generation_id=excluded.active_generation_id,updated_at=excluded.updated_at;
 return receipt;
end $$;
create function coach.fail_weekly_generation_v1(generation_id uuid,claim_token uuid,error_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;g coach.coach_generations;now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());
begin u:=integration.require_identity_v1('hermes');perform integration.lock_owner_v1(u);
 if error_code is null or length(error_code) not between 1 and 64 or error_code !~ '^[a-z0-9_]+$' then raise exception 'invalid_contract' using errcode='PT422';end if;
 update coach.coach_generations set status='failed',claim_token=null,claim_expires_at=null,error_code=fail_weekly_generation_v1.error_code,finished_at=now_at
 where user_id=u and id=fail_weekly_generation_v1.generation_id and status='running' and claim_token=fail_weekly_generation_v1.claim_token returning * into g;
 if g.id is null then raise exception 'claim_conflict' using errcode='PT409';end if;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'generation_id',g.id,'status',g.status,'finished_at',g.finished_at);
end $$;

grant select on health.profiles,health.sync_state,health.daily_metrics,health.activity_day_states,health.activities to coach_executor;
grant execute on function health.get_period_summary_v1(date,integer),health.metric_period_v1(text,date,date) to coach_executor;
grant select on coach.coach_insights,coach.weekly_publications,coach.coach_generations to integration_executor;
create policy integration_executor_insights_read on coach.coach_insights for select to integration_executor using(user_id=(select integration.current_user_id()));
grant create on schema coach to coach_executor;
grant coach_executor to postgres with admin option;
alter function coach.begin_weekly_generation_v1(date,text,bigint) owner to coach_executor;
alter function coach.renew_generation_lease_v1(uuid,uuid) owner to coach_executor;
alter function coach.persist_weekly_insights_v1(uuid,uuid,bigint,jsonb) owner to coach_executor;
alter function coach.fail_weekly_generation_v1(uuid,uuid,text) owner to coach_executor;
alter function coach.weekly_input_v1(uuid,date) owner to coach_executor;
alter function coach.expected_weekly_evidence_v1(uuid,date,bigint,jsonb,jsonb) owner to coach_executor;
revoke create on schema coach from coach_executor;
revoke execute on all functions in schema coach from public,anon,authenticated;
grant execute on function coach.weekly_input_v1(uuid,date),coach.expected_weekly_evidence_v1(uuid,date,bigint,jsonb,jsonb),
 coach.begin_weekly_generation_v1(date,text,bigint),coach.renew_generation_lease_v1(uuid,uuid),
 coach.persist_weekly_insights_v1(uuid,uuid,bigint,jsonb),coach.fail_weekly_generation_v1(uuid,uuid,text)
 to hermes_reader,coach_executor;
grant execute on function coach.get_coach_insights_v1(date,date,text,integer) to authenticated;
grant execute on function integration.current_user_id() to authenticated,hermes_reader,health_executor,coach_executor,integration_executor;

-- Telegram linking uses short-lived hashed challenges and a verified private chat.
create function integration.create_telegram_link_challenge_impl_v1() returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;raw bytea;token text;cid uuid;e timestamptz:=date_trunc('milliseconds',clock_timestamp())+interval '10 minutes';
begin
 if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 u:=integration.require_identity_v1('android');perform integration.lock_owner_v1(u);
 raw:=extensions.gen_random_bytes(32);token:=translate(rtrim(encode(raw,'base64'),'='),'+/','-_');cid:=gen_random_uuid();
 update integration.telegram_link_challenges set expires_at=clock_timestamp() where user_id=u and consumed_at is null;
 insert into integration.telegram_link_challenges(id,user_id,token_hash,expires_at)
 values(cid,u,encode(extensions.digest(raw,'sha256'),'hex'),e);
 return jsonb_build_object('contract_version',1,'computed_at',clock_timestamp(),'challenge_id',cid,'token',token,'expires_at',e,'replayed',false);
end $$;
create function integration.get_telegram_link_state_impl_v1() returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;l integration.telegram_links;c integration.telegram_link_challenges;now_at timestamptz:=clock_timestamp();
begin if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 u:=integration.require_identity_v1('android');select * into l from integration.telegram_links where user_id=u and revoked_at is null;
 select * into c from integration.telegram_link_challenges where user_id=u and consumed_at is null and expires_at>now_at order by created_at desc limit 1;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false,'linked',l.user_id is not null,
  'verified_at',l.verified_at,'active_challenge_id',c.id,'challenge_expires_at',c.expires_at);
end $$;
create function integration.revoke_telegram_link_impl_v1(request jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;op uuid;h text;old integration.operation_receipts;l integration.telegram_links;now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());outv jsonb;
begin
 if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 u:=integration.require_identity_v1('android');perform integration.lock_owner_v1(u);
 perform integration.check_keys_v1(request,array['contract_version','operation_id','issued_at','expected_verified_at']);
 if request->'contract_version' is distinct from '1'::jsonb or request->>'operation_id' is null then raise exception 'invalid_contract' using errcode='PT422';end if;
 op:=(request->>'operation_id')::uuid;h:=integration.hash_v1(request);
 select * into old from integration.operation_receipts where user_id=u and operation_id=op;
 if found then if old.operation_kind<>'revoke_telegram_link' or old.request_hash<>h then raise exception 'operation_conflict' using errcode='PT409';end if;
 return old.response||'{"replayed":true}'::jsonb;end if;
 if (request->>'issued_at')::timestamptz<now_at-interval '7 days' or (request->>'issued_at')::timestamptz>now_at+interval '5 minutes'
 then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into l from integration.telegram_links where user_id=u and revoked_at is null for update;
 if (l.user_id is null and request->'expected_verified_at'<>'null'::jsonb) or
  (l.user_id is not null and abs(extract(epoch from (l.verified_at-(request->>'expected_verified_at')::timestamptz)))>0.0005) then
  raise exception 'link_conflict' using errcode='PT409';end if;
 if l.user_id is not null then update integration.telegram_links set revoked_at=now_at where user_id=u;end if;
 update integration.telegram_link_challenges set expires_at=clock_timestamp() where user_id=u and consumed_at is null;
 outv:=jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false,'linked',false,'revoked_at',now_at);
 insert into integration.operation_receipts(user_id,operation_id,operation_kind,request_hash,response) values(u,op,'revoke_telegram_link',h,outv);
 return outv;
end $$;
create function integration.mark_insight_impl_v1(p_insight_id uuid,p_action text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid;r coach.coach_insights;st coach.insight_user_state;now_at timestamptz:=date_trunc('milliseconds',clock_timestamp());n bigint;
begin
 if session_user<>'authenticator' then raise exception 'access_denied' using errcode='PT403';end if;
 u:=integration.require_identity_v1('android');
 if p_action not in('read','dismiss') then raise exception 'invalid_contract' using errcode='PT422';end if;
 select * into r from coach.coach_insights where user_id=u and id=p_insight_id;
 if not found then raise exception 'not_found' using errcode='PT404';end if;
 insert into coach.insight_user_state(user_id,insight_id,read_at,dismissed_at,updated_at)
 values(u,r.id,case when p_action='read' then now_at end,case when p_action='dismiss' then now_at end,now_at)
 on conflict(user_id,insight_id) do update set
 read_at=coalesce(coach.insight_user_state.read_at,excluded.read_at),
 dismissed_at=coalesce(coach.insight_user_state.dismissed_at,excluded.dismissed_at),updated_at=now_at returning * into st;
 select count(*) into n from coach.coach_insights i left join coach.insight_user_state s on s.user_id=i.user_id and s.insight_id=i.id
 where i.user_id=u and i.state='published' and s.read_at is null and s.dismissed_at is null;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false,'id',r.id,'read_at',st.read_at,'dismissed_at',st.dismissed_at,'unread_count',n);
end $$;
create function integration.consume_telegram_link_challenge_v1(token text,telegram_user_id bigint,chat_id bigint,chat_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid;raw bytea;c integration.telegram_link_challenges;l integration.telegram_links;now_at timestamptz:=clock_timestamp();
begin
 u:=integration.require_identity_v1('hermes');
 if chat_type is distinct from 'private' or telegram_user_id is null or telegram_user_id<=0 or chat_id is null or chat_id<=0
  or token is null or token !~ '^[A-Za-z0-9_-]{43}$' then raise exception 'link_unavailable' using errcode='PT404';end if;
 begin raw:=decode(translate(token,'-_','+/')||'=', 'base64');exception when others then raise exception 'link_unavailable' using errcode='PT404';end;
 if length(raw)<>32 then raise exception 'link_unavailable' using errcode='PT404';end if;
 perform integration.lock_owner_v1(u);
 select * into c from integration.telegram_link_challenges where user_id=u and token_hash=encode(extensions.digest(raw,'sha256'),'hex') for update;
 if c.id is null then raise exception 'link_unavailable' using errcode='PT404';end if;
 if c.consumed_at is not null then
  select * into l from integration.telegram_links where user_id=u and revoked_at is null;
  if c.consumed_telegram_user_id=telegram_user_id and c.consumed_chat_id=chat_id and l.telegram_user_id=telegram_user_id and l.chat_id=chat_id then
   return jsonb_build_object('contract_version',1,'computed_at',now_at,'linked',true,'replayed',true);
  end if;
  raise exception 'link_unavailable' using errcode='PT404';
 end if;
 if c.expires_at<=now_at or exists(select 1 from integration.telegram_links q where q.user_id<>u and
   (q.telegram_user_id=consume_telegram_link_challenge_v1.telegram_user_id or q.chat_id=consume_telegram_link_challenge_v1.chat_id))
 then raise exception 'link_unavailable' using errcode='PT404';end if;
 update integration.telegram_link_challenges set consumed_at=now_at,consumed_telegram_user_id=telegram_user_id,consumed_chat_id=chat_id where id=c.id;
 insert into integration.telegram_links(user_id,telegram_user_id,chat_id,verified_at,revoked_at)
 values(u,telegram_user_id,chat_id,now_at,null)
 on conflict(user_id) do update set telegram_user_id=excluded.telegram_user_id,chat_id=excluded.chat_id,verified_at=now_at,revoked_at=null;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'linked',true,'verified_at',now_at,'replayed',false);
end $$;
create function integration.get_telegram_insight_context_v1(insight_id uuid,telegram_user_id bigint,chat_id bigint,chat_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid;i coach.coach_insights;l integration.telegram_links;now_at timestamptz:=clock_timestamp();
begin
 u:=integration.require_identity_v1('hermes');
 if chat_type is distinct from 'private' or telegram_user_id is null or chat_id is null then raise exception 'context_unavailable' using errcode='PT404';end if;
 select * into l from integration.telegram_links where user_id=u and revoked_at is null and
   telegram_links.telegram_user_id=get_telegram_insight_context_v1.telegram_user_id and telegram_links.chat_id=get_telegram_insight_context_v1.chat_id;
 if not found then raise exception 'context_unavailable' using errcode='PT404';end if;
 select * into i from coach.coach_insights where user_id=u and id=get_telegram_insight_context_v1.insight_id and state='published'
  and coach.is_active_publication(user_id,generation_id,period_start);
 if not found then raise exception 'context_unavailable' using errcode='PT404';end if;
 return jsonb_build_object('contract_version',1,'computed_at',now_at,'replayed',false,'id',i.id,'period_start',i.period_start,
  'period_end',i.period_end,'title',i.title,'body',i.body,'evidence',i.evidence);
end $$;
create function api.create_telegram_link_challenge_v1() returns jsonb language sql volatile security invoker set search_path='' as $$
 select integration.create_telegram_link_challenge_impl_v1()
$$;
create function api.get_telegram_link_state_v1() returns jsonb language sql stable security invoker set search_path='' as $$
 select integration.get_telegram_link_state_impl_v1()
$$;
create function api.revoke_telegram_link_v1(request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$
 select integration.revoke_telegram_link_impl_v1(request)
$$;
create or replace function api.mark_insight_v1(insight_id uuid,action text) returns jsonb language sql volatile security invoker set search_path='' as $$
 select integration.mark_insight_impl_v1(insight_id,action)
$$;
grant integration_executor to postgres with admin option;
grant create on schema integration to integration_executor;
alter function integration.create_telegram_link_challenge_impl_v1() owner to integration_executor;
alter function integration.get_telegram_link_state_impl_v1() owner to integration_executor;
alter function integration.revoke_telegram_link_impl_v1(jsonb) owner to integration_executor;
alter function integration.mark_insight_impl_v1(uuid,text) owner to integration_executor;
alter function integration.consume_telegram_link_challenge_v1(text,bigint,bigint,text) owner to integration_executor;
alter function integration.get_telegram_insight_context_v1(uuid,bigint,bigint,text) owner to integration_executor;
revoke create on schema integration from integration_executor;
grant select,insert,update on integration.telegram_links,integration.telegram_link_challenges,integration.operation_receipts,coach.insight_user_state to integration_executor;
grant select on coach.coach_insights,coach.weekly_publications,coach.coach_generations to integration_executor;
grant execute on function integration.current_user_id() to authenticated,hermes_reader,health_executor,coach_executor,integration_executor;
revoke execute on all functions in schema integration from public,anon,authenticated,hermes_reader;
revoke execute on function integration.require_identity_v1(text),integration.check_keys_v1(jsonb,text[],text[]),
 integration.jcs_v1(jsonb),integration.hash_v1(jsonb),integration.lock_owner_v1(uuid),integration.check_instant_v1(text,boolean) from public,anon,authenticated,hermes_reader;
grant execute on function integration.require_identity_v1(text),integration.check_keys_v1(jsonb,text[],text[]),
 integration.jcs_v1(jsonb),integration.hash_v1(jsonb),integration.lock_owner_v1(uuid),integration.check_instant_v1(text,boolean)
 to health_executor,coach_executor,integration_executor;
grant execute on function integration.create_telegram_link_challenge_impl_v1(),integration.get_telegram_link_state_impl_v1(),
 integration.revoke_telegram_link_impl_v1(jsonb),integration.mark_insight_impl_v1(uuid,text) to authenticated,integration_executor;
grant execute on function integration.consume_telegram_link_challenge_v1(text,bigint,bigint,text),
 integration.get_telegram_insight_context_v1(uuid,bigint,bigint,text) to hermes_reader,integration_executor;
revoke execute on all functions in schema api from public,anon;
grant execute on function api.create_telegram_link_challenge_v1(),api.get_telegram_link_state_v1(),api.revoke_telegram_link_v1(jsonb),
 api.mark_insight_v1(uuid,text) to authenticated;
grant execute on function coach.is_active_publication(uuid,uuid,date) to authenticated,coach_executor,integration_executor;

revoke execute on function health.context_v1() from hermes_reader; grant execute on function health.context_v1() to authenticated;
grant execute on function integration.current_user_id(),integration.require_identity_v1(text) to authenticated,hermes_reader,health_executor,coach_executor,integration_executor;
