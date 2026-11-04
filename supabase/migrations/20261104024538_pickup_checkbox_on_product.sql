-- Pickup is an order choice on the original product, not another product.
alter table public.farmer_orders add column pickup_requested boolean not null default false;
-- Retire the mistaken variant; keep legacy identifiers available for history.
update public.farmer_products set active=false where id='hopungmi-3kg-pickup';


CREATE OR REPLACE FUNCTION public.farmer_quote_batch(p_deliveries jsonb, p_code text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item jsonb; p public.farmer_products; c farmer_private.discount_codes; lines jsonb:='[]'; line jsonb;
 subtotal integer:=0; discount integer:=0; remaining integer:=0; part integer; weight bigint:=0; qty integer; rate integer:=0;
 v_code text:=upper(normalize(btrim(coalesce(p_code,'')),NFKC)); eligible boolean:=false;
begin
 if jsonb_typeof(p_deliveries) is distinct from 'array' then raise exception '배송지를 추가해 주세요.'; end if;
 if jsonb_array_length(p_deliveries) not between 1 and 20 then raise exception '배송지는 한 번에 1~20곳까지 신청할 수 있습니다.'; end if;
 if length(v_code)>40 then raise exception '할인코드를 확인해 주세요.'; end if;
 if v_code<>'' then
  select * into c from farmer_private.discount_codes where code=v_code and active and deleted_at is null;
  if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
  if c.usage_limit is not null and farmer_private.discount_used(c.id)>=c.usage_limit then raise exception '사용 수량이 모두 소진된 할인코드입니다.'; end if;
  remaining:=c.amount;rate:=case when c.mode='percent' then c.percent else 0 end;
 end if;
 for item in select value from jsonb_array_elements(p_deliveries) loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception '상품과 수량을 확인해 주세요.'; end if;
  if item ? 'fulfillment_method' and (jsonb_typeof(item->'fulfillment_method')<>'string' or item->>'fulfillment_method' not in ('shipping','pickup')) then raise exception '수령 방법을 확인해 주세요.';end if;
  qty:=(item->>'quantity')::integer;
  if qty not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
  select * into p from public.farmer_products where id=item->>'product_id' and active;
  if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
  part:=0;
  if v_code<>'' then
   if c.mode='percent' then part:=floor(p.price::numeric*qty*c.percent/100)::integer;
   elsif c.mode='fixed' then part:=least(p.price*qty,remaining);remaining:=remaining-part;
   elsif p.id=c.product_id and not eligible then part:=least(p.price,c.amount);eligible:=true;
   end if;
  end if;
  line:=jsonb_build_object('product_id',p.id,'product_name',p.name,'fulfillment_method',case when (farmer_private.is_pickup_product(p.id) or item->>'fulfillment_method'='pickup') then 'pickup' else 'shipping' end,'quantity',qty,'weight_grams',p.weight_grams*qty,
    'unit_price',p.price,'subtotal',p.price*qty,'discount_code',case when part>0 then v_code else null end,
    'discount_amount',part,'discount_percent',rate,'shipping_fee',0,'total',p.price*qty-part);
  lines:=lines||jsonb_build_array(line);subtotal:=subtotal+p.price*qty;discount:=discount+part;weight:=weight+p.weight_grams*qty;
 end loop;
 if v_code<>'' and c.mode='product_unit' and not eligible then raise exception '이 할인코드는 지정된 상품이 포함된 주문에 사용할 수 있습니다.'; end if;
 return jsonb_build_object('deliveries',lines,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,
 'discount_percent',rate,'shipping_fee',0,'weight_grams',weight,'total',subtotal-discount);
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_submit_batch(p_request_id uuid, p_customer_name text, p_phone text, p_deliveries jsonb, p_coupon_code text, p_expected_total integer, p_privacy_consent boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare fingerprint text; previous farmer_private.order_batches; q jsonb; d jsonb; line jsonb; o public.farmer_orders;
 receipt jsonb; receipts jsonb:='[]'; idx integer:=0; phone_value text; recipient_phone_value text; stock bigint; coupon_id uuid;
begin
 if p_request_id is null then raise exception '주문 요청 번호가 없습니다.'; end if;
 if p_privacy_consent is distinct from true then raise exception '주문 정보 저장에 동의해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array(btrim(p_customer_name),regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g'),p_deliveries,upper(btrim(coalesce(p_coupon_code,''))),p_expected_total)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.order_batches where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다. 주문 정보를 다시 확인해 주세요.'; end if;
  return previous.receipt;
 end if;
 if exists(select 1 from public.farmer_orders where request_id=p_request_id) then raise exception '이미 사용한 요청 번호입니다.'; end if;
 if p_customer_name is null or length(btrim(p_customer_name)) not between 1 and 40 then raise exception '주문자 이름을 확인해 주세요.'; end if;
 phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
 if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '연락처를 확인해 주세요.'; end if;
 coupon_id:=farmer_private.lock_discount(p_coupon_code);
 q:=public.farmer_quote_batch(p_deliveries,p_coupon_code);
 if p_expected_total is null or p_expected_total<>(q->>'total')::integer then raise exception '판매 금액이 변경되었습니다. 주문서를 다시 확인해 주세요.'; end if;
 select available_grams into stock from public.farmer_inventory where id;
 if stock<(q->>'weight_grams')::bigint then raise exception '전체 주문 수량에 비해 재고가 부족합니다. 수량을 줄여 주세요.'; end if;
 for d in select value from jsonb_array_elements(p_deliveries) loop
  idx:=idx+1;line:=q->'deliveries'->(idx-1);
  if coalesce(length(btrim(d->>'recipient_name')),0) not between 1 and 40 then raise exception '%번째 받는 분 성함을 확인해 주세요.',idx; end if;
  recipient_phone_value:=regexp_replace(coalesce(d->>'recipient_phone',''),'[[:space:]()-]','','g');
  if recipient_phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '%번째 받는 분 연락처를 확인해 주세요.',idx; end if;
  if line->>'fulfillment_method'<>'pickup' then
   if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
   if coalesce(length(btrim(d->>'address')),0) not between 5 and 200 then raise exception '배송 정보를 확인해 주세요.'; end if;
  end if;
  if length(coalesce(d->>'address_detail',''))>120 or length(coalesce(d->>'memo',''))>300 then raise exception '배송 정보를 확인해 주세요.'; end if;
  insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,address_detail,memo,batch_id,delivery_index,recipient_name,recipient_phone,postal_code,pickup_requested)
  values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,(line->>'unit_price')::integer,(line->>'subtotal')::integer,line->>'discount_code',(line->>'discount_amount')::integer,0,(line->>'total')::integer,btrim(p_customer_name),phone_value,case when line->>'fulfillment_method'='pickup' then '원북면 원이로 804-59' else btrim(d->>'address') end,case when line->>'fulfillment_method'='pickup' then '홍세환 소셜라운지' else btrim(coalesce(d->>'address_detail','')) end,btrim(coalesce(d->>'memo','')),p_request_id,idx,btrim(d->>'recipient_name'),recipient_phone_value,case when line->>'fulfillment_method'='pickup' then '' else d->>'postal_code' end,line->>'fulfillment_method'='pickup') returning * into o;
  receipts:=receipts||jsonb_build_array(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'total',o.total,'created_at',o.created_at,'delivery_index',idx));
 end loop;
 receipt:=jsonb_build_object('orders',receipts,'total',q->'total','created_at',now());
 insert into farmer_private.order_batches values(p_request_id,fingerprint,receipt,now());
 if coupon_id is not null and (q->>'discount_amount')::integer>0 then
  insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount) values(p_request_id,coupon_id,q->>'discount_code',(q->>'discount_amount')::integer);
 end if;
 return receipt;
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_admin_create_gifts(p_request_id uuid, p_deliveries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d jsonb; normalized jsonb := '[]'; line jsonb; p public.farmer_products;
  previous farmer_private.order_batches; fingerprint text; phone_value text;
  total_weight bigint := 0; balance bigint; idx integer := 0; qty integer;
  o public.farmer_orders; receipt jsonb; receipts jsonb := '[]'; actor_id uuid;
begin
  perform farmer_private.require_admin();
  actor_id := auth.uid();
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  if jsonb_typeof(p_deliveries) is distinct from 'array' then raise exception '받는 분을 추가해 주세요.'; end if;
  if jsonb_array_length(p_deliveries) not between 1 and 20 then raise exception '선물은 한 번에 1~20곳까지 등록할 수 있습니다.'; end if;
  -- A stable request identity is checked before catalog/stock checks on retries.
  fingerprint := md5(jsonb_build_array('admin-gift',actor_id,p_deliveries)::text);
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  select * into previous from farmer_private.order_batches where request_id=p_request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다. 새 선물 주문으로 등록해 주세요.'; end if;
    return previous.receipt;
  end if;
  for d in select value from jsonb_array_elements(p_deliveries) loop
    idx:=idx+1;
    if jsonb_typeof(d) is distinct from 'object' or coalesce(d->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception '%번째 상품과 수량을 확인해 주세요.',idx; end if;
    if nullif(btrim(d->>'gift_sponsor'),'') is not null and btrim(d->>'gift_sponsor') not in ('윤가희','홍세환','윤가희&홍세환') then raise exception '선물하는 사람을 선택해 주세요.'; end if;
    if d ? 'fulfillment_method' and (jsonb_typeof(d->'fulfillment_method')<>'string' or d->>'fulfillment_method' not in ('shipping','pickup')) then raise exception '수령 방법을 확인해 주세요.';end if;
    qty := (d->>'quantity')::integer;
    if qty not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
    select * into p from public.farmer_products where id=d->>'product_id' and (active or farmer_private.is_pickup_product(id));
    if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
    if coalesce(length(btrim(d->>'recipient_name')),0) not between 1 and 40 then raise exception '%번째 받는 분 성함을 확인해 주세요.',idx; end if;
    phone_value:=regexp_replace(coalesce(d->>'recipient_phone',''),'[[:space:]()-]','','g');
    if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '%번째 받는 분 연락처를 확인해 주세요.',idx; end if;
    if (not (farmer_private.is_pickup_product(p.id) or coalesce(d->>'fulfillment_method','shipping')='pickup')) then
      if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
      if coalesce(length(btrim(d->>'address')),0) not between 5 and 200 or length(coalesce(d->>'address_detail',''))>120 then raise exception '%번째 배송 정보를 확인해 주세요.',idx;end if;
    end if;
    if length(coalesce(d->>'memo',''))>300 then raise exception '%번째 배송 정보를 확인해 주세요.',idx;end if;
    line := jsonb_build_object('fulfillment_method',case when (farmer_private.is_pickup_product(p.id) or coalesce(d->>'fulfillment_method','shipping')='pickup') then 'pickup' else 'shipping' end,'product_id',p.id,'product_name',p.name,'quantity',qty,'gift_sponsor',nullif(btrim(d->>'gift_sponsor'),''),
      'weight_grams',p.weight_grams::bigint*qty,'recipient_name',btrim(d->>'recipient_name'),
      'recipient_phone',phone_value,'postal_code',case when (farmer_private.is_pickup_product(p.id) or coalesce(d->>'fulfillment_method','shipping')='pickup') then '' else d->>'postal_code' end,
      'address',case when (farmer_private.is_pickup_product(p.id) or coalesce(d->>'fulfillment_method','shipping')='pickup') then '원북면 원이로 804-59' else btrim(d->>'address') end,
      'address_detail',case when (farmer_private.is_pickup_product(p.id) or coalesce(d->>'fulfillment_method','shipping')='pickup') then '홍세환 소셜라운지' else btrim(coalesce(d->>'address_detail','')) end,'memo',btrim(coalesce(d->>'memo','')));
    normalized := normalized || jsonb_build_array(line);
    total_weight := total_weight + p.weight_grams::bigint*qty;
  end loop;
  select available_grams into balance from public.farmer_inventory where id for update;
  if balance is null or balance < total_weight then raise exception '남은 재고가 부족합니다. 선물 수량을 줄여 주세요.'; end if;
  idx:=0;
  for line in select value from jsonb_array_elements(normalized) loop
    idx:=idx+1;
    insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,
      unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,
      recipient_name,recipient_phone,postal_code,address,address_detail,memo,privacy_consented_at,
      status,confirmed_at,order_kind,created_by,batch_id,delivery_index,gift_sponsor,pickup_requested)
    values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,
      0,0,null,0,0,0,'어쩌다 농부','',line->>'recipient_name',line->>'recipient_phone',line->>'postal_code',
      line->>'address',line->>'address_detail',line->>'memo',null,'confirmed',now(),'gift',actor_id,p_request_id,idx,line->>'gift_sponsor',line->>'fulfillment_method'='pickup')
    returning * into o;
    balance := balance-o.weight_grams;
    insert into public.farmer_stock_events(delta_grams,balance_grams,reason,order_id,actor)
      values(-o.weight_grams,balance,'선물 주문 등록',o.id,actor_id);
    insert into public.farmer_order_events(id,order_id,from_status,to_status,actor)
      values(gen_random_uuid(),o.id,'new','confirmed',actor_id);
    receipts:=receipts||jsonb_build_array(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),
      'order_kind','gift','status','confirmed','total',0,'delivery_index',idx,'created_at',o.created_at));
  end loop;
  update public.farmer_inventory set available_grams=balance,version=version+1,updated_at=now() where id;
  receipt:=jsonb_build_object('orders',receipts,'order_kind','gift','total',0,'weight_grams',total_weight,'created_at',now());
  insert into farmer_private.order_batches(request_id,fingerprint,receipt) values(p_request_id,fingerprint,receipt);
  return receipt;
end $function$;


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
   or (o.status='shipped' and (p_status in ('delivered','shipped_unpaid') or ((o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) and p_status='cancelled')))
   or (o.status='shipped_unpaid' and p_status='shipped')) then raise exception '변경할 수 없는 주문 상태입니다.'; end if;
  if p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') and (not (o.pickup_requested or farmer_private.is_pickup_product(o.product_id))) and btrim(coalesce(p_carrier,''))='' then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
  if p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') and (not (o.pickup_requested or farmer_private.is_pickup_product(o.product_id))) then
    parcels:=farmer_private.parcel_tracking_numbers(p_tracking_number,o.quantity);
    if left(btrim(coalesce(p_tracking_number,'')),1)<>'[' and btrim(coalesce(p_tracking_number,''))=o.tracking_number and cardinality(o.tracking_numbers)>1 then parcels:=o.tracking_numbers; end if;
  else parcels:='{}'; end if;
  previous:=o.status;
  if o.status='pending' and p_status in ('confirmed','shipped_unpaid') then delta:=-o.weight_grams;
  elsif p_status='cancelled' and (o.status='confirmed' or ((o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) and o.status='shipped')) then delta:=o.weight_grams; end if;
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
    carrier=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then case when (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) then '방문 수령' else btrim(p_carrier) end else carrier end,
    tracking_number=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then case when (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) then '' else coalesce((select n from unnest(parcels) with ordinality t(n,i) where n<>'' order by i limit 1),'') end else tracking_number end,
    tracking_numbers=case when p_status in ('shipped','shipped_unpaid') and o.status in ('pending','confirmed') then parcels else tracking_numbers end
    where id=o.id returning * into o;
  insert into public.farmer_order_events(id,order_id,from_status,to_status,actor,request_fingerprint) values(p_request_id,o.id,previous,p_status,auth.uid(),fingerprint);
  return jsonb_build_object('status',o.status,'version',o.version);
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
 if (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) then
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


CREATE OR REPLACE FUNCTION public.farmer_lookup_orders(p_customer_name text, p_phone text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  name_value text; phone_value text; attempts_value integer; window_value timestamptz;
  rows jsonb; count_value bigint; next_value integer;
begin
  if length(coalesce(p_customer_name,''))>40 or length(coalesce(p_phone,''))>40
     or p_offset is null or p_offset<0 or p_offset>100000 then
    return jsonb_build_object('found',false);
  end if;
  name_value:=btrim(coalesce(p_customer_name,''));
  phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
  if length(name_value)=0 or phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then
    return jsonb_build_object('found',false);
  end if;
  -- Return failures, rather than raising, so rate-limit counters are committed.
  delete from farmer_private.order_lookup_limits where window_started<now()-interval '1 day';
  insert into farmer_private.order_lookup_limits(bucket) values('phone:'||md5(phone_value))
  on conflict(bucket) do update set
    attempts=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then 1 else least(order_lookup_limits.attempts+1,100000) end,
    window_started=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then now() else order_lookup_limits.window_started end
  returning attempts,window_started into attempts_value,window_value;
  if attempts_value>20 then
    return jsonb_build_object('found',false,'retry_after',greatest(1,ceil(extract(epoch from window_value+interval '15 minutes'-now()))::integer));
  end if;
  select count(*) into count_value from public.farmer_orders where deleted_at is null and order_kind='sale' and customer_name=name_value and phone=phone_value;
  if count_value=0 then return jsonb_build_object('found',false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_number','GF-'||lpad(o.order_no::text,8,'0'),
    'product_name',o.product_name,'fulfillment_method',case when (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)) then 'pickup' else 'shipping' end,'quantity',o.quantity,'subtotal',o.subtotal,
    'discount_amount',o.discount_amount,'shipping_fee',o.shipping_fee,'total',o.total,'status',o.status,
    'recipient_name',left(coalesce(nullif(o.recipient_name,''),o.customer_name),1)||repeat('*',least(3,greatest(1,length(coalesce(nullif(o.recipient_name,''),o.customer_name))-1))),
    'created_at',o.created_at,'delivered_at',o.delivered_at
  ) order by o.created_at desc,o.order_no desc),'[]'::jsonb) into rows
  from (select * from public.farmer_orders where deleted_at is null and order_kind='sale' and customer_name=name_value and phone=phone_value
        order by created_at desc,order_no desc limit 20 offset p_offset) o;
  next_value:=case when p_offset+20<count_value then p_offset+20 else null end;
  return jsonb_build_object('found',true,'orders',rows,'total_count',count_value,'next_offset',next_value);
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_admin_hanjin_preview(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item jsonb;result jsonb:='[]';candidates jsonb;reason text;phone_value text;name_value text;track text;
begin
 perform farmer_private.require_admin();
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 500 or length(p_rows::text)>1000000 then raise exception '1~500상자의 한진 배송 내역을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$')
 or (select count(distinct x->>'row') from jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) then raise exception '엑셀 행 정보를 확인해 주세요.';end if;
 for item in select value from jsonb_array_elements(p_rows) loop
  track:=coalesce(item->>'tracking','');phone_value:=regexp_replace(coalesce(item->>'phone',''),'[[:space:]()-]','','g');name_value:=farmer_private.hanjin_name(item->>'name');reason:='';candidates:='[]';
  if track !~ '^[0-9]{12}$' then reason:='한진 운송장번호 12자리를 확인해 주세요.';
  elsif (select count(*) from jsonb_array_elements(p_rows) x where x->>'tracking'=track)>1 then reason:='파일 안에 같은 송장번호가 중복되어 있습니다.';
  elsif coalesce(item->>'quantity','')<>'1' then reason:='송장 한 개당 수량은 1상자여야 합니다.';
  elsif coalesce(item->>'weight_grams','') not in ('2000','3000','5000') then reason:='품목명의 2kg·3kg·5kg 중량을 확인해 주세요.';
  elsif length(name_value)>100 or length(name_value)=0 or length(regexp_replace(phone_value,'[^0-9]','','g'))<6 or length(phone_value)>20 or phone_value !~ '^[0-9*]+$'
   or coalesce(item->>'postal','') !~ '^[0-9]{5}$' or length(coalesce(item->>'address','')) not between 5 and 250 then reason:='받는 분 이름·연락처·우편번호·주소를 확인해 주세요.';
  elsif coalesce(item->>'order_number','')<>'' and item->>'order_number' !~ '^GF-[0-9]{8}$' then reason:='주문번호 형식을 확인해 주세요.';
  else
   select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number','GF-'||lpad(o.order_no::text,8,'0'),'recipient_name',coalesce(nullif(o.recipient_name,''),o.customer_name),'customer_name',o.customer_name,'quantity',o.quantity,'version',o.version,'status',o.status,'existing',track=any(o.tracking_numbers) or track=o.tracking_number,'carrier',o.carrier) order by o.created_at desc,o.id),'[]') into candidates
   from public.farmer_orders o
   where o.deleted_at is null and o.status<>'cancelled' and (not (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)))
    and not exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null)
    and (coalesce(item->>'order_number','')='' or 'GF-'||lpad(o.order_no::text,8,'0')=item->>'order_number')
    and o.weight_grams=o.quantity::bigint*(item->>'weight_grams')::integer
    and o.postal_code=item->>'postal'
    and farmer_private.hanjin_address(item->>'address') in (farmer_private.hanjin_address(o.address),farmer_private.hanjin_address(o.address||' '||o.address_detail))
    and farmer_private.hanjin_mask(farmer_private.hanjin_name(coalesce(nullif(o.recipient_name,''),o.customer_name)),name_value)
    and farmer_private.hanjin_mask(regexp_replace(coalesce(nullif(o.recipient_phone,''),o.phone),'[[:space:]()-]','','g'),phone_value)
    and not exists(select 1 from public.farmer_orders other where other.id<>o.id and (track=any(other.tracking_numbers) or track=other.tracking_number));
   if jsonb_array_length(candidates)=0 then reason:='일치하는 주문이 없거나 다른 주문에 등록된 송장입니다.';end if;
  end if;
  result:=result||jsonb_build_array(jsonb_build_object('row',(item->>'row')::integer,'tracking',track,'name',item->>'name','weight_grams',item->>'weight_grams','candidates',candidates,'reason',reason));
 end loop;
 return jsonb_build_object('rows',result,'count',jsonb_array_length(p_rows));
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
  select quantity, product_id, pickup_requested from public.farmer_orders
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
  'shipping_boxes',coalesce((select sum(quantity) from eligible where (not (pickup_requested or farmer_private.is_pickup_product(product_id)))),0),
  'pickup_boxes',coalesce((select sum(quantity) from eligible where (pickup_requested or farmer_private.is_pickup_product(product_id))),0),
  'recorded_shipping',costs.recorded_shipping,'recorded_packing',costs.recorded_packing)
 into result from costs;
 return result;
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_admin_free_gift_summary(p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;start_at timestamptz;end_at timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 then raise exception '조회 연도를 확인해 주세요.';end if;
 start_at:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');end_at:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with units as (
  select o.id,o.status,o.product_id,o.pickup_requested,o.weight_grams/o.quantity as unit_grams,
   case when o.order_kind='gift' then o.quantity
    else least(o.quantity,floor(o.discount_amount::numeric/nullif(o.unit_price,0))::integer) end as free_boxes,
   case when o.order_kind='gift' then coalesce(o.gift_sponsor,case when g.sender_name in ('윤가희','홍세환','윤가희&홍세환') then g.sender_name end,'미지정')
    when o.discount_code='고구맙습니다홍세환선물용' then '홍세환' else '윤가희' end as sponsor
  from public.farmer_orders o left join farmer_private.gift_links g on g.order_id=o.id
  where o.deleted_at is null and o.status in ('pending','confirmed','shipped','delivered') and o.created_at>=start_at and o.created_at<end_at
   and ((o.order_kind='gift' and o.total=0) or (o.order_kind='sale' and o.discount_code in ('고구맙습니다홍세환선물용','고구맙습니다윤가희선물용') and o.unit_price>0 and o.discount_amount>=o.unit_price))
 ),gifts as (select * from units where free_boxes>0),
 people as (
  select n.sponsor,coalesce(sum(g.free_boxes),0) as boxes,coalesce(sum(g.free_boxes*g.unit_grams),0)/1000.0 as kg,
   coalesce(sum(g.free_boxes) filter(where g.product_id in ('hopungmi-5kg','hopungmi-5kg-pickup')),0) as qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id in ('hopungmi-5kg','hopungmi-5kg-pickup') and (g.pickup_requested or farmer_private.is_pickup_product(g.product_id))),0) as pickup_qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-5kg' and not g.pickup_requested),0) as shipping_qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id in ('hopungmi-3kg','hopungmi-3kg-pickup')),0) as qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id in ('hopungmi-3kg','hopungmi-3kg-pickup') and (g.pickup_requested or farmer_private.is_pickup_product(g.product_id))),0) as pickup_qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-3kg' and not g.pickup_requested),0) as shipping_qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-2kg'),0) as qty2,
   coalesce(sum(g.free_boxes) filter(where g.status='pending'),0) as pending_boxes
  from (values('윤가희',1),('홍세환',2),('윤가희&홍세환',3),('미지정',4))n(sponsor,position) left join gifts g on g.sponsor=n.sponsor group by n.sponsor,n.position order by n.position
 )
 select jsonb_build_object('year',p_year,'totals',jsonb_build_object(
  'boxes',coalesce(sum(free_boxes),0),'kg',coalesce(sum(free_boxes*unit_grams),0)/1000.0,
  'qty5',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-5kg','hopungmi-5kg-pickup')),0),
  'pickup_qty5',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-5kg','hopungmi-5kg-pickup') and (pickup_requested or farmer_private.is_pickup_product(product_id))),0),
  'shipping_qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg' and not pickup_requested),0),
  'qty3',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-3kg','hopungmi-3kg-pickup')),0),
  'pickup_qty3',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-3kg','hopungmi-3kg-pickup') and (pickup_requested or farmer_private.is_pickup_product(product_id))),0),
  'shipping_qty3',coalesce(sum(free_boxes) filter(where product_id='hopungmi-3kg' and not pickup_requested),0),
  'qty2',coalesce(sum(free_boxes) filter(where product_id='hopungmi-2kg'),0),
  'pending_boxes',coalesce(sum(free_boxes) filter(where status='pending'),0),
  'reserved_boxes',coalesce(sum(free_boxes) filter(where status<>'pending'),0)),
  'people',(select jsonb_agg(to_jsonb(p)) from people p)) into result from gifts;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_quote_gifts(p_deliveries jsonb, p_code text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q jsonb;c farmer_private.discount_codes;uses integer;
begin
 q:=public.farmer_quote_batch(p_deliveries,p_code);
 if exists(select 1 from jsonb_array_elements(p_deliveries) d where (farmer_private.is_pickup_product(d->>'product_id') or d->>'fulfillment_method'='pickup')) then
  raise exception '선물은 택배 상품을 선택해 주세요.';
 end if;
 if (q->>'discount_amount')::integer>0 then
  uses:=jsonb_array_length(p_deliveries);
  select * into strict c from farmer_private.discount_codes where code=q->>'discount_code';
  if c.usage_limit is not null and farmer_private.discount_used(c.id)+uses>c.usage_limit then
   raise exception '할인코드의 남은 사용 횟수보다 받는 분이 많습니다. 받는 분 수를 줄이거나 할인코드를 변경해 주세요.';
  end if;
 end if;
 return q;
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_buy_gifts(p_request_id uuid, p_customer_name text, p_phone text, p_sender_name text, p_items jsonb, p_code text, p_expected_total integer, p_privacy_consent boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare previous farmer_private.order_batches; fp text; phone_value text; q jsonb; d jsonb; line jsonb;
 o public.farmer_orders; idx integer:=0; token_value text; links jsonb:='[]'; result jsonb; stock bigint; coupon_id uuid;
begin
 if p_request_id is null or p_privacy_consent is distinct from true then raise exception '주문 정보 저장에 동의해 주세요.'; end if;
 phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
 if coalesce(length(btrim(p_customer_name)),0) not between 1 and 40 or coalesce(length(btrim(p_sender_name)),0) not between 1 and 40 then raise exception '보내는 분 성함을 확인해 주세요.'; end if;
 if phone_value !~ '^0[0-9]{8,10}$' then raise exception '연락처를 확인해 주세요.'; end if;
 fp:=md5(jsonb_build_array('gift-purchase',btrim(p_customer_name),phone_value,btrim(p_sender_name),p_items,p_code,p_expected_total)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.order_batches where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 if exists(select 1 from public.farmer_orders where request_id=p_request_id) then raise exception '이미 사용한 요청 번호입니다.'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' then raise exception '받는 분을 추가해 주세요.'; end if;
 if jsonb_array_length(p_items) not between 1 and 20 then raise exception '선물은 한 번에 1~20명까지 신청할 수 있습니다.'; end if;
 if (select count(*) from public.farmer_orders where phone=phone_value and status='pending' and created_at>now()-interval '1 day')>=100 then raise exception '입금 대기 주문이 많습니다. 판매자에게 문의해 주세요.'; end if;
 for d in select value from jsonb_array_elements(p_items) loop
  if (farmer_private.is_pickup_product(d->>'product_id') or d->>'fulfillment_method'='pickup') then raise exception '선물은 택배 상품을 선택해 주세요.'; end if;
  if coalesce(length(btrim(d->>'recipient_label')),0) not between 1 and 40 or length(coalesce(d->>'message',''))>300 then raise exception '받는 분 이름과 메시지를 확인해 주세요.'; end if;
 end loop;
 coupon_id:=farmer_private.lock_discount(p_code);
 q:=public.farmer_quote_gifts(p_items,p_code);
 if p_expected_total is null or p_expected_total<>(q->>'total')::integer then raise exception '판매 금액이 변경되었습니다. 금액을 다시 확인해 주세요.'; end if;
 select available_grams into stock from public.farmer_inventory where id;
 if stock<(q->>'weight_grams')::bigint then raise exception '남은 재고가 부족합니다.'; end if;
 for d in select value from jsonb_array_elements(p_items) loop
  line:=q->'deliveries'->idx;idx:=idx+1;
  insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,batch_id,delivery_index,recipient_name,recipient_phone,postal_code)
  values(gen_random_uuid(),fp,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,(line->>'unit_price')::integer,(line->>'subtotal')::integer,line->>'discount_code',(line->>'discount_amount')::integer,0,(line->>'total')::integer,btrim(p_customer_name),phone_value,'',p_request_id,idx,btrim(d->>'recipient_label'),'','') returning * into o;
  token_value:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into farmer_private.gift_links(order_id,token,sender_name,recipient_label,message)
   values(o.id,token_value,btrim(p_sender_name),btrim(d->>'recipient_label'),btrim(coalesce(d->>'message','')));
  links:=links||jsonb_build_array(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'token',token_value,'recipient_label',btrim(d->>'recipient_label'),'product_name',o.product_name,'quantity',o.quantity,'total',o.total));
 end loop;
 result:=jsonb_build_object('gifts',links,'total',q->'total','created_at',now());
 insert into farmer_private.order_batches(request_id,fingerprint,receipt) values(p_request_id,fp,result);
 if coupon_id is not null and (q->>'discount_amount')::integer>0 then
  insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount) values(p_request_id,coupon_id,q->>'discount_code',(q->>'discount_amount')::integer);
 end if;
 return result;
end $function$;


CREATE OR REPLACE FUNCTION public.farmer_catalog()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'weight_grams', p.weight_grams,
        'price', p.price,
        'fulfillment_method', case when farmer_private.is_pickup_product(p.id) then 'pickup' else 'shipping' end,
        'available', p.active and i.available_grams >= p.weight_grams
      ) order by p.weight_grams, case when farmer_private.is_pickup_product(p.id) then 1 else 0 end, p.id), '[]'::jsonb)
      from public.farmer_products p cross join public.farmer_inventory i
      where (p.active or p.id = 'hopungmi-2kg') and not farmer_private.is_pickup_product(p.id)
    ),
    'shipping_fee', 0,
    'pickup_location', jsonb_build_object('address', '원북면 원이로 804-59', 'name', '홍세환 소셜라운지')
  );
$function$;


do $$ declare definition text;begin
 definition:=pg_get_viewdef('farmer_private.admin_order_rows'::regclass,true);
 definition:=replace(definition,'product_id = ''hopungmi-5kg-pickup''::text','(pickup_requested or farmer_private.is_pickup_product(product_id))');
 execute 'create or replace view farmer_private.admin_order_rows as '||definition;
end $$;

