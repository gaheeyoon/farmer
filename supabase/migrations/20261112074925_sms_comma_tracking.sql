-- Keep every parcel in one message; separate waybills with comma and space.
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
  elsif phone_value !~ '^01[0-9]{8,9}$' or n='' then reason:='받는 분 이름과 연락처를 확인해 주세요.';
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
