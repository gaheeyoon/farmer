-- Ordinary pickup uses the current delivery price; saved historical orders stay unchanged.
update public.farmer_products set price=22000,active=true where id='hopungmi-5kg-pickup';
-- Shipping on credit is a distinct, unpaid state. No existing orders are reclassified.
alter table public.farmer_orders drop constraint farmer_orders_status_check;
alter table public.farmer_orders add constraint farmer_orders_status_check
 check(status in ('pending','confirmed','shipped','shipped_unpaid','delivered','cancelled'));

CREATE OR REPLACE FUNCTION public.farmer_admin_change_status(p_order_id uuid, p_status text, p_expected_version bigint, p_request_id uuid, p_carrier text DEFAULT ''::text, p_tracking_number text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.farmer_orders; balance bigint; delta bigint:=0; previous text; old_event public.farmer_order_events; parcels text[]; fingerprint text;
begin
  perform farmer_private.require_admin();
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
  if p_status is null or p_status not in ('confirmed', 'shipped', 'shipped_unpaid', 'delivered') then
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

CREATE OR REPLACE FUNCTION public.farmer_admin_export_orders(p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;count_all integer;
begin
 perform farmer_private.require_admin();
 if length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','shipped','shipped_unpaid','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 -- One snapshot, bounded memory. Never silently truncate an export.
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb),count(*) into rows,count_all from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 10001)t;
 if count_all>10000 then raise exception '한 번에 10,000건까지 내려받을 수 있습니다. 검색 조건을 좁혀 주세요.';end if;
 return jsonb_build_object('orders',rows,'total',count_all,'exported_at',now());
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_order_list(p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_kind text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;count_all bigint;
begin
 perform farmer_private.require_admin();
 if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','shipped','shipped_unpaid','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 select count(*) into count_all from farmer_private.filtered_admin_orders(p_status,p_search,p_kind);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb) into rows from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 50 offset p_offset)t;
 return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare data jsonb;
begin
 perform farmer_private.require_admin();
 select jsonb_build_object(
  'available_kg',i.available_grams/1000.0,'inventory_version',i.version,'inventory_updated_at',i.updated_at,
  'pending',a.pending,'pending_kg',a.pending_kg,
  'confirmed',a.confirmed,'confirmed_kg',a.confirmed_kg,
  'confirmed_2kg_boxes',a.confirmed_2kg_boxes,'confirmed_5kg_boxes',a.confirmed_5kg_boxes,
  'shipped',a.shipped,'shipped_kg',a.shipped_kg,
  'shipped_unpaid',a.shipped_unpaid,'shipped_unpaid_kg',a.shipped_unpaid_kg,'shipped_unpaid_amount',a.shipped_unpaid_amount,
  'delivered',a.delivered,'delivered_kg',a.delivered_kg
 ) into data from public.farmer_inventory i cross join (
  select count(*) filter(where status='pending') as pending,
   coalesce(sum(weight_grams) filter(where status='pending'),0)/1000.0 as pending_kg,
   count(*) filter(where status='confirmed') as confirmed,
   coalesce(sum(weight_grams) filter(where status='confirmed'),0)/1000.0 as confirmed_kg,
   coalesce(sum(quantity) filter(where status='confirmed' and weight_grams=quantity::bigint*2000),0) as confirmed_2kg_boxes,
   coalesce(sum(quantity) filter(where status='confirmed' and weight_grams=quantity::bigint*5000),0) as confirmed_5kg_boxes,
   count(*) filter(where status='shipped_unpaid') as shipped_unpaid,
   coalesce(sum(weight_grams) filter(where status='shipped_unpaid'),0)/1000.0 as shipped_unpaid_kg,
   coalesce(sum(total) filter(where status='shipped_unpaid'),0) as shipped_unpaid_amount,
   count(*) filter(where status='shipped') as shipped,
   coalesce(sum(weight_grams) filter(where status='shipped'),0)/1000.0 as shipped_kg,
   count(*) filter(where status='delivered') as delivered,
   coalesce(sum(weight_grams) filter(where status='delivered'),0)/1000.0 as delivered_kg
  from public.farmer_orders where deleted_at is null
 ) a where i.id;
 return data;
end $function$;

CREATE OR REPLACE FUNCTION farmer_private.guard_gift_fulfillment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g farmer_private.gift_links;
begin
 select * into g from farmer_private.gift_links where order_id=new.id for update;
 if found then
  if new.status in ('shipped','shipped_unpaid','delivered') and g.claimed_at is null then
   raise exception '받는 분이 배송지를 등록한 뒤 발송할 수 있습니다.';
  end if;
  if old.status='pending' and new.status='confirmed' then
   update farmer_private.gift_links set expires_at=now()+interval '30 days' where order_id=new.id;
  end if;
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_update_delivery(p_order_id uuid, p_expected_version bigint, p_request_id uuid, p_delivery jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.farmer_orders; g farmer_private.gift_links; previous farmer_private.delivery_edit_requests;
 actor_id uuid:=auth.uid(); d jsonb; fp text; has_link boolean; changes text[]; parcels text[];
begin
 perform farmer_private.require_admin();
 if p_order_id is null or p_request_id is null or p_expected_version is null or p_expected_version<1
   or jsonb_typeof(p_delivery) is distinct from 'object' or length(p_delivery::text)>20000 then raise exception '수정할 배송 정보를 확인해 주세요.'; end if;
 if exists(select 1 from jsonb_each(p_delivery) e where jsonb_typeof(e.value)<>'string') then raise exception '배송 정보 형식을 확인해 주세요.'; end if;
 if exists(select 1 from jsonb_object_keys(p_delivery) k where k not in ('recipient_name','recipient_phone','postal_code','address','address_detail','memo','carrier','tracking_number')) then
  raise exception '배송 정보에 수정할 수 없는 항목이 있습니다.';
 end if;
 d:=jsonb_build_object(
  'recipient_name',btrim(coalesce(p_delivery->>'recipient_name','')),
  'recipient_phone',regexp_replace(coalesce(p_delivery->>'recipient_phone',''),'[[:space:]()-]','','g'),
  'postal_code',btrim(coalesce(p_delivery->>'postal_code','')),
  'address',btrim(coalesce(p_delivery->>'address','')),
  'address_detail',btrim(coalesce(p_delivery->>'address_detail','')),
  'memo',btrim(coalesce(p_delivery->>'memo','')),
  'carrier',btrim(coalesce(p_delivery->>'carrier','')),
  'tracking_number',btrim(coalesce(p_delivery->>'tracking_number',''))
 );
 if length(d->>'recipient_name') not between 1 and 40 or d->>'recipient_phone' !~ '^0[0-9]{8,10}$'
  or length(d->>'postal_code')>5 or length(d->>'address')>200 or length(d->>'address_detail')>120
  or length(d->>'memo')>300 or length(d->>'carrier')>60 or length(d->>'tracking_number')>15000 then raise exception '받는 분과 배송 정보를 확인해 주세요.'; end if;
 fp:=md5(jsonb_build_array(actor_id,p_order_id,p_expected_version,d)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.delivery_edit_requests where request_id=p_request_id;
 if found then
  if previous.actor<>actor_id or previous.order_id<>p_order_id or previous.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return jsonb_build_object('saved',true,'version',previous.order_version);
 end if;
 -- Use the same order -> gift lock order as recipient claim/status changes.
 select * into o from public.farmer_orders where id=p_order_id for update;
 if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
 if o.version<>p_expected_version then raise exception '다른 화면에서 주문이 변경되었습니다. 닫은 뒤 새로고침하고 다시 수정해 주세요.'; end if;
 select * into g from farmer_private.gift_links where order_id=o.id for update;has_link:=found;
 if has_link and g.claimed_at is null and o.status<>'confirmed' then raise exception '배송지가 등록되지 않은 선물은 입금 확인 후 수정해 주세요.'; end if;
 if o.product_id='hopungmi-5kg-pickup' then
  -- A delivery edit must never turn pickup into shipping or change its location.
  d:=d||jsonb_build_object('postal_code',o.postal_code,'address',o.address,'address_detail',o.address_detail,'carrier',o.carrier,'tracking_number',o.tracking_number,'tracking_numbers',to_jsonb(o.tracking_numbers));
 else
  parcels:=farmer_private.parcel_tracking_numbers(d->>'tracking_number',o.quantity);
  if left(d->>'tracking_number',1)<>'[' and d->>'tracking_number'=o.tracking_number and cardinality(o.tracking_numbers)>1 then parcels:=o.tracking_numbers; end if;
  d:=d||jsonb_build_object('tracking_numbers',to_jsonb(parcels),'tracking_number',coalesce((select n from unnest(parcels) with ordinality t(n,i) where n<>'' order by i limit 1),''));
  if d->>'postal_code' !~ '^[0-9]{5}$' or length(d->>'address')<5 then raise exception '우편번호와 주소를 확인해 주세요.'; end if;
  if o.status in ('shipped','shipped_unpaid','delivered') and length(d->>'carrier')=0 then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
 end if;
 select coalesce(array_agg(k),'{}'::text[]) into changes from jsonb_object_keys(d) k where d->>k is distinct from to_jsonb(o)->>k;
 update public.farmer_orders set
  recipient_name=d->>'recipient_name',recipient_phone=d->>'recipient_phone',postal_code=d->>'postal_code',
  address=d->>'address',address_detail=d->>'address_detail',memo=d->>'memo',carrier=d->>'carrier',tracking_number=d->>'tracking_number',
  tracking_numbers=array(select jsonb_array_elements_text(d->'tracking_numbers')),
  version=version+1,updated_at=now() where id=o.id returning * into o;
 if has_link and g.claimed_at is null then
  update farmer_private.gift_links set claimed_at=now(),claim_request_id=p_request_id,
   claim_fingerprint=md5(jsonb_build_array(o.recipient_name,o.recipient_phone,o.postal_code,o.address,o.address_detail)::text)
  where order_id=o.id;
 end if;
 insert into farmer_private.delivery_edit_requests(request_id,order_id,actor,fingerprint,order_version,changed_fields)
 values(p_request_id,o.id,actor_id,fp,o.version,changes);
 return jsonb_build_object('saved',true,'version',o.version);
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_fulfillment_costs(p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; starts timestamptz; ends timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 then raise exception '연도를 확인해 주세요.'; end if;
 starts:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');
 ends:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with eligible as (
  select quantity, product_id from public.farmer_orders
  where deleted_at is null and status in ('confirmed','shipped','shipped_unpaid','delivered')
   and coalesce(confirmed_at,shipped_at,created_at)>=starts and coalesce(confirmed_at,shipped_at,created_at)<ends
 ), costs as (
  select coalesce(sum(amount) filter(where category='배송비'),0) as recorded_shipping,
   coalesce(sum(amount) filter(where category='포장비'),0) as recorded_packing
  from farmer_private.finance_entries where deleted_at is null and direction='expense'
   and occurred_on>=make_date(p_year,1,1) and occurred_on<make_date(p_year+1,1,1)
 )
 select jsonb_build_object('year',p_year,
  'settings',(select jsonb_build_object('shipping',shipping,'packing',packing,'version',version) from farmer_private.fulfillment_cost_settings where singleton),
  'shipping_boxes',coalesce((select sum(quantity) from eligible where product_id<>'hopungmi-5kg-pickup'),0),
  'pickup_boxes',coalesce((select sum(quantity) from eligible where product_id='hopungmi-5kg-pickup'),0),
  'recorded_shipping',costs.recorded_shipping,'recorded_packing',costs.recorded_packing)
 into result from costs;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_finance_report(p_year integer, p_kind text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; starts timestamptz; ends timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 or coalesce(p_kind,'') not in ('','income','expense')
   or length(coalesce(p_search,''))>100 or p_offset is null or p_offset not between 0 and 1000000 then raise exception '조회 조건을 확인해 주세요.'; end if;
 starts:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');ends:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with paid as (
  select * from public.farmer_orders o where o.order_kind='sale' and o.status in ('confirmed','shipped','delivered')
   and coalesce(o.confirmed_at,o.created_at)>=starts and coalesce(o.confirmed_at,o.created_at)<ends
 ), ledger as (
  select 'manual'::text as source,e.id,e.occurred_on,e.direction,e.category,e.title,e.counterparty,e.note,e.amount,
    e.quantity,e.unit_price,e.version,null::text as order_number
  from farmer_private.finance_entries e where e.deleted_at is null and e.occurred_on>=make_date(p_year,1,1) and e.occurred_on<make_date(p_year+1,1,1)
  union all
  select 'order',o.id,(coalesce(o.confirmed_at,o.created_at) at time zone 'Asia/Seoul')::date,'income','고구마 판매',
    o.product_name||' × '||o.quantity::text,o.customer_name,
    case o.status when 'confirmed' then '입금 확인(배송 준비)' when 'shipped' then '배송 중' else '배송 완료' end,
    o.total::bigint,o.quantity::numeric,o.unit_price::bigint,o.version,'GF-'||lpad(o.order_no::text,8,'0')
  from paid o
 ), filtered as (
  select * from ledger l where (coalesce(p_kind,'')='' or l.direction=p_kind)
   and (coalesce(p_search,'')='' or position(lower(p_search) in lower(l.title||' '||l.category||' '||l.counterparty||' '||l.note||' '||coalesce(l.order_number,'')))>0)
 ), monthly as (
  select m as month,coalesce(sum(l.amount) filter(where l.direction='income'),0) as income,
    coalesce(sum(l.amount) filter(where l.direction='expense'),0) as expense
  from generate_series(1,12) m left join ledger l on extract(month from l.occurred_on)=m group by m
 )
 select jsonb_build_object('year',p_year,'summary',jsonb_build_object(
   'order_income',coalesce((select sum(total) from paid),0),
   'manual_income',coalesce((select sum(amount) from ledger where source='manual' and direction='income'),0),
   'expense',coalesce((select sum(amount) from ledger where direction='expense'),0),
   'profit',coalesce((select sum(case when direction='income' then amount else -amount end) from ledger),0),
   'order_count',(select count(*) from paid),'sold_kg',coalesce((select sum(weight_grams)::numeric/1000 from paid),0),
   'collected_shipping',coalesce((select sum(shipping_fee) from paid),0),
   'outstanding_income',coalesce((select sum(total) from public.farmer_orders where deleted_at is null and order_kind='sale' and status='shipped_unpaid' and shipped_at>=starts and shipped_at<ends),0),
   'pending_income',coalesce((select sum(total) from public.farmer_orders where order_kind='sale' and status='pending' and created_at>=starts and created_at<ends),0)),
   'categories',coalesce((select jsonb_agg(to_jsonb(t) order by t.amount desc,t.category) from
      (select category,sum(amount) as amount from ledger where direction='expense' group by category)t),'[]'::jsonb),
   'months',(select jsonb_agg(to_jsonb(m) order by m.month) from monthly m),
   'entries',coalesce((select jsonb_agg(to_jsonb(t) order by t.occurred_on desc,t.source,t.id) from
      (select * from filtered order by occurred_on desc,source,id limit 50 offset p_offset)t),'[]'::jsonb),
   'total',(select count(*) from filtered),'offset',p_offset,'limit',50) into result;
 return result;
end $function$;

-- Replaced functions retain their existing explicit grants. No new public API or table access is granted.
