-- Permit domestic mobile numbers and Smart Store 12-digit 0502 relay numbers.
-- Keep templates, recipient numbers, request receipts and deduplication unchanged.
CREATE OR REPLACE FUNCTION farmer_private.sms_prepare(p_orders jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r jsonb;o public.farmer_orders;t farmer_private.sms_templates;n text;phone_value text;tracks text[];body_value text;reason text;prior text;signature text;out_rows jsonb:='[]';
begin
 if jsonb_typeof(p_orders) is distinct from 'array' or jsonb_array_length(p_orders) not between 1 and 100 then raise exception '문자 보낼 주문을 1~100건 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_orders) x where coalesce(x->>'order_id','') !~* '^[a-f0-9-]{36}$' or coalesce(x->>'expected_version','') !~ '^[0-9]{1,15}$') or (select count(distinct x->>'order_id') from jsonb_array_elements(p_orders) x)<>jsonb_array_length(p_orders) then raise exception '선택한 주문을 확인해 주세요.';end if;
 for r in select value from jsonb_array_elements(p_orders) loop
  select * into strict o from public.farmer_orders where id=(r->>'order_id')::uuid;
  reason:='';prior:='';body_value:='';n:=coalesce(nullif(o.recipient_name,''),o.customer_name);phone_value:=regexp_replace(coalesce(nullif(o.recipient_phone,''),o.phone),'[^0-9]','','g');
  tracks:=array(select regexp_replace(v,'[[:space:]-]','','g') from unnest(case when cardinality(o.tracking_numbers)>0 then o.tracking_numbers else array[o.tracking_number] end) with ordinality u(v,i) order by i);
  select * into t from farmer_private.sms_templates where weight=o.weight_grams/o.quantity;
  if o.version::text<>r->>'expected_version' then reason:='주문이 변경되었습니다. 목록을 새로고침해 주세요.';
  elsif o.deleted_at is not null or o.status<>'shipped' then reason:='배송 중 주문만 배송 안내를 보낼 수 있습니다.';
  elsif o.pickup_requested or farmer_private.is_pickup_product(o.product_id) then reason:='방문 수령 주문입니다.';
  elsif phone_value !~ '^(01[0-9]{8,9}|0502[0-9]{8})$' or n='' then reason:='받는 분 이름과 연락처를 확인해 주세요.';
  elsif cardinality(tracks)<>o.quantity or exists(select 1 from unnest(tracks) v where v !~ '^[0-9A-Za-z]{6,100}$') or (select count(distinct v) from unnest(tracks) v)<>o.quantity then reason:='상자마다 실제 송장번호를 입력해 주세요.';
  elsif t.weight is null then reason:='이 중량의 기본 문자가 없습니다.';
  else
   body_value:=replace(replace(replace(replace(t.body,'[이름]',n),'[송장번호]',array_to_string(tracks,', ')),'[송장]',array_to_string(tracks,', ')),'[중량]',(t.weight/1000)::text||'kg');
  end if;
  signature:=md5(jsonb_build_array(o.id,o.version,phone_value,tracks,body_value)::text);
  if exists(select 1 from farmer_private.sms_messages m where m.kind='delivery' and m.order_id=o.id and m.phone=phone_value and m.tracking_numbers=tracks and m.state in ('queued','processing','uncertain')) then prior:='진행 중이거나 확인이 필요한 발송이 있습니다.';
  elsif not exists(select 1 from unnest(tracks) v where not exists(select 1 from farmer_private.sms_messages m where m.kind in ('delivery','legacy') and m.phone=phone_value and v=any(m.tracking_numbers) and m.state in ('sent','legacy'))) then prior:='발송 기록 있음';end if;
  out_rows:=out_rows||jsonb_build_array(jsonb_build_object('order_id',o.id,'order_number','GF-'||lpad(o.order_no::text,8,'0'),'expected_version',o.version,'signature',signature,'name',n,'phone',phone_value,'weight',o.weight_grams/o.quantity,'boxes',o.quantity,'tracking_numbers',tracks,'carrier',o.carrier,'body',body_value,'reason',reason,'prior',prior));
 end loop;
 return out_rows;
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_sms(p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;items jsonb;item jsonb;previous farmer_private.sms_requests;id_value uuid;secret text;d farmer_private.sms_devices;entry farmer_private.sms_messages;o public.farmer_orders;fp text;created_count integer:=0;count_value bigint;request_value uuid;phone_value text;body_value text;signature_value text;offset_value integer;legacy_key_value text;
begin
 perform farmer_private.require_admin();
 if jsonb_typeof(p_data) is distinct from 'object' or length(p_data::text)>1000000 then raise exception '문자 요청을 확인해 주세요.';end if;
 if p_action in ('config','list','marks') then update farmer_private.sms_messages set state='uncertain',error='처리 결과를 확인하지 못했습니다. Mac 메시지 앱을 확인해 주세요.',finished_at=now() where state='processing' and claimed_at<now()-interval '5 minutes';end if;
 if p_action='config' then
  select jsonb_build_object('templates',(select jsonb_agg(to_jsonb(t) order by weight) from farmer_private.sms_templates t),'devices',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'last_seen',last_seen,'online',active and expires_at>now() and last_seen>now()-interval '90 seconds') order by created_at desc),'[]') from farmer_private.sms_devices where active)) into result;return result;
 elsif p_action='template_save' then
  if coalesce(p_data->>'weight','') not in ('3000','5000') or coalesce(length(btrim(p_data->>'body')),0) not between 1 and 5000 or (p_data->>'body' not like '%[이름]%' or (p_data->>'body' not like '%[송장]%' and p_data->>'body' not like '%[송장번호]%')) then raise exception '이름과 송장 항목을 포함한 기본 문자를 입력해 주세요.';end if;
  update farmer_private.sms_templates set body=btrim(p_data->>'body'),version=version+1,updated_at=now() where weight=(p_data->>'weight')::integer and version=(p_data->>'version')::bigint returning to_jsonb(sms_templates.*) into result;
  if result is null then raise exception '문구가 변경되었습니다. 다시 불러와 주세요.';end if;return result;
 elsif p_action='pair' then
  if (select count(*) from farmer_private.sms_devices where active)>20 then raise exception '연결한 Mac을 정리해 주세요.';end if;
  secret:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into farmer_private.sms_devices(name,secret_hash) values(left(coalesce(nullif(btrim(p_data->>'name'),''),'문자 발송 Mac'),40),encode(sha256(convert_to(secret,'UTF8')),'hex')) returning * into d;
  return jsonb_build_object('id',d.id,'secret',secret);
 elsif p_action='revoke' then
  update farmer_private.sms_devices set active=false where id=(p_data->>'device_id')::uuid;
  update farmer_private.sms_messages set state='cancelled',finished_at=now() where device_id=(p_data->>'device_id')::uuid and state='queued';return jsonb_build_object('saved',true);
 elsif p_action='marks' then
  items:=farmer_private.sms_prepare(p_data->'orders');
  select coalesce(jsonb_agg(jsonb_build_object('order_id',x->>'order_id','state',coalesce((select m.state from farmer_private.sms_messages m where m.order_id=(x->>'order_id')::uuid and m.kind='delivery' and m.phone=x->>'phone' and m.tracking_numbers=array(select jsonb_array_elements_text(x->'tracking_numbers')) order by m.created_at desc,m.id limit 1),case when x->>'prior'='발송 기록 있음' then 'legacy' else '' end))),'[]') into result from jsonb_array_elements(items) x;
  return jsonb_build_object('items',result);
 elsif p_action='prepare' then return jsonb_build_object('items',farmer_private.sms_prepare(p_data->'orders'));
 elsif p_action in ('queue','test') then
  request_value:=(p_data->>'request_id')::uuid;if request_value is null then raise exception '발송 요청 번호가 없습니다.';end if;
  fp:=md5(jsonb_build_array(auth.uid(),p_action,p_data)::text);perform pg_advisory_xact_lock(hashtextextended('sms:'||request_value::text,0));
  select * into previous from farmer_private.sms_requests where id=request_value;
  if found then if previous.actor<>auth.uid() or previous.fingerprint<>fp then raise exception '이미 사용한 발송 요청입니다.';end if;return previous.receipt;end if;
  select * into d from farmer_private.sms_devices where id=(p_data->>'device_id')::uuid for update;
  if not found or not d.active or d.expires_at<=now() or d.last_seen is null or d.last_seen<now()-interval '90 seconds' then raise exception 'Mac 발송 프로그램을 실행하고 연결을 확인해 주세요.';end if;
  items:=farmer_private.sms_prepare(p_data->'orders');
  if p_action='test' and jsonb_array_length(items)<>1 then raise exception '테스트할 주문을 한 건 선택해 주세요.';end if;
  for item in select value from jsonb_array_elements(items) loop
   select value->>'signature' into signature_value from jsonb_array_elements(p_data->'orders') where value->>'order_id'=item->>'order_id';
   if signature_value is distinct from item->>'signature' or item->>'reason'<>'' then raise exception '주문 또는 기본 문자가 변경되었습니다. 미리보기를 다시 확인해 주세요.';end if;
   if p_action='queue' then
    if item->>'prior' like '진행 중%' then raise exception '이미 진행 중인 발송입니다. 발송 기록을 확인해 주세요.';end if;
    if item->>'prior'<>'' and coalesce((p_data->>'allow_resend')::boolean,false)=false then raise exception '이미 발송한 주문이 포함되어 있습니다.';end if;
   end if;
   phone_value:=case when p_action='test' then regexp_replace(coalesce(p_data->>'test_phone',''),'[^0-9]','','g') else item->>'phone' end;
   if phone_value !~ '^(01[0-9]{8,9}|0502[0-9]{8})$' then raise exception '테스트 받을 연락처를 확인해 주세요.';end if;
   insert into farmer_private.sms_messages(request_id,order_id,order_version,device_id,kind,dedup_key,order_number,name,phone,weight,boxes,tracking_numbers,body,actor)
   values(request_value,(item->>'order_id')::uuid,(item->>'expected_version')::bigint,d.id,case when p_action='test' then 'test' else 'delivery' end,
    case when p_action='test' then gen_random_uuid()::text else md5(jsonb_build_array(item->>'order_id',phone_value,item->'tracking_numbers')::text) end,
    item->>'order_number',item->>'name',phone_value,(item->>'weight')::integer,(item->>'boxes')::integer,array(select jsonb_array_elements_text(item->'tracking_numbers')),item->>'body',auth.uid());created_count:=created_count+1;
  end loop;
  result:=jsonb_build_object('saved',true,'count',created_count,'request_id',request_value);
  insert into farmer_private.sms_requests values(request_value,auth.uid(),fp,result);return result;
 elsif p_action='list' then
  offset_value:=coalesce((p_data->>'offset')::integer,0);if offset_value not between 0 and 100000 then raise exception '조회 위치를 확인해 주세요.';end if;
  select count(*) into count_value from farmer_private.sms_messages where coalesce(p_data->>'state','')='' or state=p_data->>'state';
  select coalesce(jsonb_agg(to_jsonb(m) order by created_at desc,id),'[]') into result from (select id,order_id,order_number,name,phone,weight,boxes,tracking_numbers,body,state,error,created_at,finished_at,kind from farmer_private.sms_messages where coalesce(p_data->>'state','')='' or state=p_data->>'state' order by created_at desc,id limit 50 offset offset_value)m;
  return jsonb_build_object('items',result,'total',count_value,'offset',offset_value);
 elsif p_action='cancel' then
  update farmer_private.sms_messages set state='cancelled',finished_at=now() where state='queued';return jsonb_build_object('saved',true);
 elsif p_action='resolve' then
  update farmer_private.sms_messages set state='cancelled',error='관리자가 메시지 앱 확인 후 재발송 준비',finished_at=now() where id=(p_data->>'id')::uuid and state='uncertain';return jsonb_build_object('saved',true);
 elsif p_action='import' then
  if jsonb_typeof(p_data->'items') is distinct from 'array' or jsonb_array_length(p_data->'items')>500 then raise exception '한 번에 기존 기록 500건까지 가져올 수 있습니다.';end if;
  for item in select value from jsonb_array_elements(p_data->'items') loop
   phone_value:=regexp_replace(coalesce(item->>'phone',''),'[^0-9]','','g');body_value:=coalesce(item->>'invoice','');
   if phone_value !~ '^(01[0-9]{8,9}|0502[0-9]{8})$' or body_value !~ '^[0-9]{12}$' or coalesce(length(item->>'name'),0) not between 1 and 100 then raise exception '기존 발송 기록을 확인해 주세요.';end if;
   legacy_key_value:=md5(jsonb_build_array(phone_value,body_value,item->>'at')::text);
   insert into farmer_private.sms_messages(kind,dedup_key,legacy_key,name,phone,tracking_numbers,state,created_at,finished_at,actor)
   values('legacy',legacy_key_value,legacy_key_value,item->>'name',phone_value,array[body_value],'legacy',(item->>'at')::timestamptz,(item->>'at')::timestamptz,auth.uid()) on conflict(legacy_key) do nothing;
   if found then created_count:=created_count+1;end if;
  end loop;return jsonb_build_object('saved',true,'count',created_count);
 end if;
 raise exception '알 수 없는 문자 작업입니다.';
end $function$;
