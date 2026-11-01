-- Five admin stages. No order records or inventory are reclassified.
create or replace function farmer_private.filtered_admin_orders(p_status text,p_search text,p_kind text)
returns setof farmer_private.admin_order_rows language sql stable set search_path='' as $$
 select o.* from farmer_private.admin_order_rows o
 where (case when p_status='deleted' then o.deleted_at is not null else o.deleted_at is null and
  (case when p_status='confirmed_waiting_address' then o.status='confirmed' and o.awaiting_address
        when p_status='confirmed_ready' then o.status='confirmed' and not o.awaiting_address
        else coalesce(p_status,'')='' or o.status=p_status end) end)
 and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
 and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' '||o.order_number))>0);
$$;

CREATE OR REPLACE FUNCTION public.farmer_admin_order_list(p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_kind text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;count_all bigint;
begin
 perform farmer_private.require_admin();
 if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','confirmed_waiting_address','confirmed_ready','shipped','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 select count(*) into count_all from farmer_private.filtered_admin_orders(p_status,p_search,p_kind);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb) into rows from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 50 offset p_offset)t;
 return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_export_orders(p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;count_all integer;
begin
 perform farmer_private.require_admin();
 if length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','confirmed_waiting_address','confirmed_ready','shipped','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 -- One snapshot, bounded memory. Never silently truncate an export.
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb),count(*) into rows,count_all from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 10001)t;
 if count_all>10000 then raise exception '한 번에 10,000건까지 내려받을 수 있습니다. 검색 조건을 좁혀 주세요.';end if;
 return jsonb_build_object('orders',rows,'total',count_all,'exported_at',now());
end $function$;

-- Count actual boxes (quantity), independently of order count, for every stage.
-- Saved order weight identifies size, including inactive SKUs and free pickup gifts.
create or replace function public.farmer_admin_summary() returns jsonb
language plpgsql security definer set search_path='' as $$
declare data jsonb; stage record;
begin
 perform farmer_private.require_admin();
 select jsonb_build_object('available_kg',available_grams/1000.0,
  'inventory_version',version,'inventory_updated_at',updated_at) into data
 from public.farmer_inventory where id;
 for stage in
  select stages.status,count(o.id) as order_count,
   coalesce(sum(o.weight_grams),0)/1000.0 as kg,
   coalesce(sum(o.quantity),0) as boxes,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*2000),0) as boxes2,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*5000),0) as boxes5,
   coalesce(sum(o.total),0) as amount
  from (values ('pending'),('confirmed'),('shipped'),('shipped_unpaid'),('delivered')) stages(status)
  left join public.farmer_orders o on o.status=stages.status and o.deleted_at is null
  group by stages.status
 loop
  data:=data||jsonb_build_object(stage.status,stage.order_count,
   stage.status||'_kg',stage.kg,stage.status||'_boxes',stage.boxes,
   stage.status||'_2kg_boxes',stage.boxes2,stage.status||'_5kg_boxes',stage.boxes5);
  if stage.status='shipped_unpaid' then
   data:=data||jsonb_build_object('shipped_unpaid_amount',stage.amount);
  end if;
 end loop;
 -- Combined confirmed counters remain compatible; the admin uses disjoint stages.
 for stage in
  select stages.status,count(o.id) as order_count,coalesce(sum(o.weight_grams),0)/1000.0 as kg,
   coalesce(sum(o.quantity),0) as boxes,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*2000),0) as boxes2,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*5000),0) as boxes5
  from (values ('confirmed_waiting_address'),('confirmed_ready')) stages(status)
  left join farmer_private.admin_order_rows o on o.status='confirmed' and o.deleted_at is null
   and (case when stages.status='confirmed_waiting_address' then o.awaiting_address else not o.awaiting_address end)
  group by stages.status
 loop
  data:=data||jsonb_build_object(stage.status,stage.order_count,stage.status||'_kg',stage.kg,
   stage.status||'_boxes',stage.boxes,stage.status||'_2kg_boxes',stage.boxes2,stage.status||'_5kg_boxes',stage.boxes5);
 end loop;
 return data;
end $$;


CREATE OR REPLACE FUNCTION public.farmer_admin_change_status(p_order_id uuid, p_status text, p_expected_version bigint, p_request_id uuid, p_carrier text DEFAULT ''::text, p_tracking_number text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.farmer_orders; balance bigint; delta bigint:=0; previous text; old_event public.farmer_order_events; parcels text[]; fingerprint text;
begin
  perform farmer_private.require_admin();
  if p_status='shipped_unpaid' then raise exception '더 이상 사용하지 않는 주문 상태입니다. 입금 확인 후 발송해 주세요.'; end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  if length(coalesce(p_carrier,''))>60 or length(coalesce(p_tracking_number,''))>15000 then raise exception '배송 정보를 확인해 주세요.'; end if;
  select * into o from public.farmer_orders where id=p_order_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  fingerprint:=md5(jsonb_build_array(auth.uid(),p_order_id,p_status,p_expected_version,p_carrier,p_tracking_number)::text);
  select * into old_event from public.farmer_order_events where id=p_request_id;
  if found then
    if old_event.order_id<>p_order_id or old_event.to_status<>p_status or (old_event.request_fingerprint is not null and old_event.request_fingerprint<>fingerprint) then raise exception '이미 사용한 요청 번호입니다.'; end if;
    return jsonb_build_object('status',o.status,'version',o.version);
  end if;
  if p_expected_version is null or o.version<>p_expected_version then raise exception '다른 화면에서 주문이 변경되었습니다. 새로고침해 주세요.'; end if;
  if p_status='shipped_unpaid' and (o.order_kind<>'sale' or o.total<=0 or exists(select 1 from farmer_private.gift_links where order_id=o.id)) then
    raise exception '미수 발송은 결제 금액이 있는 일반 주문에만 적용할 수 있습니다.';
  end if;
  if not ((o.status='pending' and p_status in ('confirmed','cancelled','shipped_unpaid'))
   or (o.status='confirmed' and p_status in ('shipped','cancelled','shipped_unpaid'))
   or (o.status='shipped' and (p_status in ('delivered','shipped_unpaid') or (o.product_id='hopungmi-5kg-pickup' and p_status='cancelled')))
   or (o.status='shipped_unpaid' and p_status='shipped')) then raise exception '변경할 수 없는 주문 상태입니다.'; end if;
  if p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') and o.product_id<>'hopungmi-5kg-pickup' and btrim(coalesce(p_carrier,''))='' then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
  if p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') and o.product_id<>'hopungmi-5kg-pickup' then
    parcels:=farmer_private.parcel_tracking_numbers(p_tracking_number,o.quantity);
    if left(btrim(coalesce(p_tracking_number,'')),1)<>'[' and btrim(coalesce(p_tracking_number,''))=o.tracking_number and cardinality(o.tracking_numbers)>1 then parcels:=o.tracking_numbers; end if;
  else parcels:='{}'; end if;
  previous:=o.status;
  if o.status='pending' and p_status in ('confirmed','shipped_unpaid') then delta:=-o.weight_grams;
  elsif p_status='cancelled' and (o.status='confirmed' or (o.product_id='hopungmi-5kg-pickup' and o.status='shipped')) then delta:=o.weight_grams; end if;
  if delta<>0 then
    select available_grams into balance from public.farmer_inventory where id for update;
    if balance+delta<0 then raise exception '재고가 부족해 주문을 확정할 수 없습니다.'; end if;
    update public.farmer_inventory set available_grams=balance+delta,version=version+1,updated_at=now() where id;
    insert into public.farmer_stock_events(delta_grams,balance_grams,reason,order_id,actor) values(delta,balance+delta,case when p_status='shipped_unpaid' then '미수 주문 발송' when delta<0 then '주문 확정' else '배송 전 주문 취소' end,o.id,auth.uid());
  end if;
  update public.farmer_orders set status=p_status,version=version+1,updated_at=now(),
    confirmed_at=case when p_status='shipped_unpaid' then null when p_status='confirmed' or (o.status='shipped_unpaid' and p_status='shipped') then now() else confirmed_at end,
    shipped_at=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then now() else shipped_at end,
    delivered_at=case when p_status='delivered' then now() else delivered_at end,
    cancelled_at=case when p_status='cancelled' then now() else cancelled_at end,
    carrier=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then case when o.product_id='hopungmi-5kg-pickup' then '방문 수령' else btrim(p_carrier) end else carrier end,
    tracking_number=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then case when o.product_id='hopungmi-5kg-pickup' then '' else coalesce((select n from unnest(parcels) with ordinality t(n,i) where n<>'' order by i limit 1),'') end else tracking_number end,
    tracking_numbers=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then parcels else tracking_numbers end
    where id=o.id returning * into o;
  insert into public.farmer_order_events(id,order_id,from_status,to_status,actor,request_fingerprint) values(p_request_id,o.id,previous,p_status,auth.uid(),fingerprint);
  return jsonb_build_object('status',o.status,'version',o.version);
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_bulk_status(p_orders jsonb, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  item record;
  result jsonb;
  results jsonb := '[]'::jsonb;
  item_count integer;
begin
  perform farmer_private.require_admin();
  if p_status is null or p_status not in ('confirmed', 'shipped', 'delivered') then
    raise exception '일괄 변경할 수 없는 주문 상태입니다.';
  end if;
  if p_orders is null or jsonb_typeof(p_orders) <> 'array' then
    raise exception '변경할 주문을 선택해 주세요.';
  end if;
  item_count := jsonb_array_length(p_orders);
  if item_count < 1 or item_count > 50 then
    raise exception '한 번에 1~50건의 주문을 변경할 수 있습니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_orders) as a(v)
    where jsonb_typeof(v) <> 'object'
       or coalesce(jsonb_typeof(v->'order_id'), '') <> 'string'
       or coalesce(jsonb_typeof(v->'request_id'), '') <> 'string'
       or coalesce(jsonb_typeof(v->'expected_version'), '') <> 'number'
       or (v->>'expected_version') !~ '^[1-9][0-9]*$'
       or (v ? 'carrier' and jsonb_typeof(v->'carrier') <> 'string')
       or (v ? 'tracking_number' and jsonb_typeof(v->'tracking_number') <> 'string')
  ) then
    raise exception '주문 변경 정보가 올바르지 않습니다.';
  end if;
  if (select count(distinct x.order_id) from jsonb_to_recordset(p_orders) as x(order_id uuid)) <> item_count
    or (select count(distinct x.request_id) from jsonb_to_recordset(p_orders) as x(request_id uuid)) <> item_count then
    raise exception '중복된 주문 또는 처리 요청이 있습니다.';
  end if;
  -- Acquire every order lock before the inventory lock, in a stable order.
  perform o.id from public.farmer_orders o
    join jsonb_to_recordset(p_orders) as x(order_id uuid) on x.order_id = o.id
    order by o.id for update of o;
  for item in select * from jsonb_to_recordset(p_orders)
    as x(order_id uuid, expected_version bigint, request_id uuid, carrier text, tracking_number text)
    order by order_id
  loop
    result := public.farmer_admin_change_status(
      item.order_id, p_status, item.expected_version, item.request_id,
      coalesce(item.carrier, ''), coalesce(item.tracking_number, '')
    );
    results := results || jsonb_build_array(result || jsonb_build_object('id', item.order_id));
  end loop;
  return jsonb_build_object('processed_count', item_count, 'orders', results);
end;
$function$;

create or replace function public.farmer_admin_import_hanjin(p_request_id uuid,p_rows jsonb,p_matches jsonb,p_mark_shipped boolean default true) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old farmer_private.hanjin_import_requests;actor_id uuid:=auth.uid();fp text;preview jsonb;item jsonb;line jsonb;candidate jsonb;
 rec record;o public.farmer_orders;original public.farmer_orders;tracking text[];incoming text;slot integer;used integer;additions integer:=0;
 changed integer:=0;advanced integer:=0;unchanged integer:=0;partial integer:=0;shipment_result jsonb;receipt jsonb;target text;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or p_mark_shipped is null then raise exception '등록 요청을 확인해 주세요.';end if;
 fp:=md5(jsonb_build_array(actor_id,p_rows,p_matches,p_mark_shipped)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into old from farmer_private.hanjin_import_requests where request_id=p_request_id;
 if found then if old.actor<>actor_id or old.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.';end if;return old.receipt;end if;
 if p_matches is null or jsonb_typeof(p_matches)<>'array' or jsonb_array_length(p_matches) not between 1 and 500 or length(p_matches::text)>100000 then raise exception '등록할 행을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_matches) x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$' or coalesce(x->>'order_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(x->>'expected_version','') !~ '^[1-9][0-9]{0,15}$')
 or (select count(distinct x->>'row') from jsonb_array_elements(p_matches) x)<>jsonb_array_length(p_matches) then raise exception '선택한 행과 주문 정보를 확인해 주세요.';end if;
 -- Stable order locks, then the existing inventory lock used by status transitions.
 perform orders.id from public.farmer_orders orders join (select distinct (x->>'order_id')::uuid id from jsonb_array_elements(p_matches) x) chosen on chosen.id=orders.id order by orders.id for update of orders;
 -- Serialize duplicate waybills across distinct import requests, including different orders.
 for rec in select distinct x->>'tracking' tracking from jsonb_array_elements(p_rows) x order by 1 loop
  perform pg_advisory_xact_lock(hashtextextended('hanjin:'||rec.tracking,0));
 end loop;
 preview:=public.farmer_admin_hanjin_preview(p_rows);
 for item in select value from jsonb_array_elements(p_matches) loop
  select value into line from jsonb_array_elements(preview->'rows') where value->>'row'=item->>'row';
  if line is null or coalesce(line->>'reason','')<>'' then raise exception '일치하지 않는 행이 포함되어 있습니다. 파일을 다시 확인해 주세요.';end if;
  select value into candidate from jsonb_array_elements(line->'candidates') where value->>'id'=item->>'order_id';
  if candidate is null then raise exception '받는 분·연락처·주소가 일치하지 않는 주문입니다.';end if;
  if candidate->>'version'<>item->>'expected_version' then raise exception '다른 화면에서 주문이 변경되었습니다. 파일을 다시 확인해 주세요.';end if;
 end loop;
 for rec in select distinct (x->>'order_id')::uuid id from jsonb_array_elements(p_matches) x order by id loop
  select * into strict o from public.farmer_orders where id=rec.id;original:=o;
  tracking:=coalesce(o.tracking_numbers,'{}');
  if cardinality(tracking)=0 and o.tracking_number<>'' then tracking:=array[o.tracking_number];end if;
  if cardinality(tracking)>o.quantity then raise exception '기존 상자별 송장 정보를 먼저 확인해 주세요.';end if;
  while cardinality(tracking)<o.quantity loop tracking:=array_append(tracking,'');end loop;
  if exists(select 1 from unnest(tracking) t where t<>'' ) and o.carrier not in ('','한진','한진택배') then raise exception '다른 택배사 송장이 있는 주문입니다. 배송 정보를 먼저 확인해 주세요.';end if;
  used:=0;
  for item in select x.value from jsonb_array_elements(p_rows) x where exists(select 1 from jsonb_array_elements(p_matches) m where m->>'row'=x.value->>'row' and (m->>'order_id')::uuid=o.id) order by (x.value->>'row')::integer loop
   incoming:=item->>'tracking';
   if not incoming=any(tracking) then
    select i into slot from generate_subscripts(tracking,1) i where tracking[i]='' order by i limit 1;
    if slot is null then raise exception '주문 수량보다 송장 수가 많습니다. 기존 송장은 덮어쓰지 않습니다.';end if;
    tracking[slot]:=incoming;used:=used+1;
   end if;
  end loop;
  if tracking is distinct from o.tracking_numbers or o.carrier<>'한진' then
   update public.farmer_orders set tracking_numbers=tracking,tracking_number=coalesce((select t from unnest(tracking) with ordinality u(t,i) where t<>'' order by i limit 1),''),carrier='한진',version=version+1,updated_at=now() where id=o.id returning * into o;
  end if;
  -- Fully discounted orders need no payment; reserve stock once before shipment.
  if p_mark_shipped and o.status='pending' and o.total=0 and not ''=any(tracking) then
   shipment_result:=public.farmer_admin_change_status(o.id,'confirmed',o.version,gen_random_uuid(),'','');
   select * into o from public.farmer_orders where id=o.id;
  end if;
  target:=case when o.status='confirmed' then 'shipped' else '' end;
  if p_mark_shipped and target<>'' and not ''=any(tracking) then
   shipment_result:=public.farmer_admin_change_status(o.id,target,o.version,gen_random_uuid(),'한진',to_jsonb(tracking)::text);
   advanced:=advanced+1;select * into o from public.farmer_orders where id=o.id;
  elsif p_mark_shipped and target<>'' and ''=any(tracking) then partial:=partial+1;
  end if;
  additions:=additions+used;
  if o.version=original.version then unchanged:=unchanged+1;
  else
   changed:=changed+1;
   insert into farmer_private.hanjin_import_orders values(p_request_id,o.id,original.version,o.version,original.tracking_numbers,tracking,original.status,o.status);
  end if;
 end loop;
 receipt:=jsonb_build_object('saved',true,'orders',changed,'parcels',additions,'shipped',advanced,'unchanged',unchanged,'partial',partial);
 insert into farmer_private.hanjin_import_requests(request_id,actor,fingerprint,receipt) values(p_request_id,actor_id,fp,receipt);
 return receipt;
end $$;
