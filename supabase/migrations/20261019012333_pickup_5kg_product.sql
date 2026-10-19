-- Dedicated pickup SKU; all products share the same stock in grams.
-- Existing orders, prices, stock and stored retry receipts remain unchanged.
insert into public.farmer_products(id,name,weight_grams,price,active)
values ('hopungmi-5kg-pickup','호풍미 5kg 방문 수령',5000,18000,true)
on conflict(id) do update set name=excluded.name,weight_grams=excluded.weight_grams,price=excluded.price,active=excluded.active;

create or replace function public.farmer_catalog() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('products',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'weight_grams',p.weight_grams,'price',p.price,'fulfillment_method',case when p.id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,'available',i.available_grams>=p.weight_grams) order by p.weight_grams,case when p.id='hopungmi-5kg-pickup' then 1 else 0 end,p.id),'[]'::jsonb) from public.farmer_products p cross join public.farmer_inventory i where p.active), 'shipping_fee',0,'pickup_location',jsonb_build_object('address','원북면 원이로 804-59','name','홍세환 소셜라운지'));
$$;

create or replace function public.farmer_quote_batch(p_deliveries jsonb,p_code text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
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
  line:=jsonb_build_object('product_id',p.id,'product_name',p.name,'fulfillment_method',case when p.id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,'quantity',qty,'weight_grams',p.weight_grams*qty,
    'unit_price',p.price,'subtotal',p.price*qty,'discount_code',case when part>0 then v_code else null end,
    'discount_amount',part,'discount_percent',rate,'shipping_fee',0,'total',p.price*qty-part);
  lines:=lines||jsonb_build_array(line);subtotal:=subtotal+p.price*qty;discount:=discount+part;weight:=weight+p.weight_grams*qty;
 end loop;
 if v_code<>'' and c.mode='product_unit' and not eligible then raise exception '이 할인코드는 지정된 상품이 포함된 주문에 사용할 수 있습니다.'; end if;
 return jsonb_build_object('deliveries',lines,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,
 'discount_percent',rate,'shipping_fee',0,'weight_grams',weight,'total',subtotal-discount);
end $$;

create or replace function public.farmer_submit_batch(p_request_id uuid,p_customer_name text,p_phone text,p_deliveries jsonb,p_coupon_code text,p_expected_total integer,p_privacy_consent boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,address_detail,memo,batch_id,delivery_index,recipient_name,recipient_phone,postal_code)
  values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,(line->>'unit_price')::integer,(line->>'subtotal')::integer,line->>'discount_code',(line->>'discount_amount')::integer,0,(line->>'total')::integer,btrim(p_customer_name),phone_value,case when line->>'fulfillment_method'='pickup' then '원북면 원이로 804-59' else btrim(d->>'address') end,case when line->>'fulfillment_method'='pickup' then '홍세환 소셜라운지' else btrim(coalesce(d->>'address_detail','')) end,btrim(coalesce(d->>'memo','')),p_request_id,idx,btrim(d->>'recipient_name'),recipient_phone_value,case when line->>'fulfillment_method'='pickup' then '' else d->>'postal_code' end) returning * into o;
  receipts:=receipts||jsonb_build_array(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'total',o.total,'created_at',o.created_at,'delivery_index',idx));
 end loop;
 receipt:=jsonb_build_object('orders',receipts,'total',q->'total','created_at',now());
 insert into farmer_private.order_batches values(p_request_id,fingerprint,receipt,now());
 if coupon_id is not null and (q->>'discount_amount')::integer>0 then
  insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount) values(p_request_id,coupon_id,q->>'discount_code',(q->>'discount_amount')::integer);
 end if;
 return receipt;
end $$;

create or replace function public.farmer_submit_order(
 p_request_id uuid,p_product_id text,p_quantity integer,p_coupon_code text,p_customer_name text,p_phone text,
 p_address text,p_address_detail text,p_memo text,p_expected_total integer,p_privacy_consent boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare q jsonb; o public.farmer_orders; fingerprint text; phone_value text; stock bigint; coupon_id uuid;
begin
  if p_request_id is null then raise exception '주문 요청 번호가 없습니다.'; end if;
  if p_privacy_consent is distinct from true then raise exception '주문 정보 저장에 동의해 주세요.'; end if;
  if p_customer_name is null or length(btrim(p_customer_name)) not between 1 and 40 then raise exception '주문자 이름을 확인해 주세요.'; end if;
  phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
  if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '연락처를 확인해 주세요.'; end if;
  if (p_product_id<>'hopungmi-5kg-pickup' and (p_address is null or length(btrim(p_address)) not between 5 and 200)) or length(coalesce(p_address_detail,''))>120 or length(coalesce(p_memo,''))>300 or length(coalesce(p_coupon_code,''))>40 then raise exception '배송 정보를 확인해 주세요.'; end if;
  fingerprint:=md5(jsonb_build_array(p_product_id,p_quantity,upper(btrim(coalesce(p_coupon_code,''))),btrim(p_customer_name),phone_value,btrim(p_address),coalesce(p_address_detail,''),coalesce(p_memo,''),p_expected_total)::text);
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  select * into o from public.farmer_orders where request_id=p_request_id;
  if found then
    if o.request_fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다. 주문 정보를 다시 확인해 주세요.'; end if;
  else
    if exists(select 1 from farmer_private.order_batches where request_id=p_request_id) then raise exception '이미 사용한 요청 번호입니다.'; end if;
    coupon_id:=farmer_private.lock_discount(p_coupon_code);
    q:=farmer_private.quote(p_product_id,p_quantity,p_coupon_code);
    if p_expected_total is null or (q->>'total')::integer<>p_expected_total then raise exception '판매 금액이 변경되었습니다. 새로고침 후 다시 확인해 주세요.'; end if;
    select available_grams into stock from public.farmer_inventory where id;
    if stock<(q->>'weight_grams')::bigint then raise exception '남은 재고가 부족합니다. 수량을 줄여 주세요.'; end if;
    -- Pending orders do not reserve stock. Stock is atomically deducted at confirmation.
    insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,address_detail,memo)
      values(p_request_id,fingerprint,p_product_id,q->>'product_name',p_quantity,(q->>'weight_grams')::bigint,(q->>'unit_price')::integer,(q->>'subtotal')::integer,q->>'discount_code',(q->>'discount_amount')::integer,(q->>'shipping_fee')::integer,(q->>'total')::integer,btrim(p_customer_name),phone_value,case when p_product_id='hopungmi-5kg-pickup' then '원북면 원이로 804-59' else btrim(p_address) end,case when p_product_id='hopungmi-5kg-pickup' then '홍세환 소셜라운지' else btrim(coalesce(p_address_detail,'')) end,btrim(coalesce(p_memo,''))) returning * into o;
    if coupon_id is not null and o.discount_amount>0 then
      insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount) values(p_request_id,coupon_id,o.discount_code,o.discount_amount);
    end if;
  end if;
  return jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'total',o.total,'created_at',o.created_at);
end $$;

create or replace function public.farmer_admin_change_status(p_order_id uuid,p_status text,p_expected_version bigint,p_request_id uuid,p_carrier text default '',p_tracking_number text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.farmer_orders; balance bigint; delta bigint:=0; previous text; old_event public.farmer_order_events;
begin
  perform farmer_private.require_admin();
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  if length(coalesce(p_carrier,''))>60 or length(coalesce(p_tracking_number,''))>100 then raise exception '배송 정보를 확인해 주세요.'; end if;
  select * into o from public.farmer_orders where id=p_order_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  select * into old_event from public.farmer_order_events where id=p_request_id;
  if found then
    if old_event.order_id<>p_order_id or old_event.to_status<>p_status then raise exception '이미 사용한 요청 번호입니다.'; end if;
    return jsonb_build_object('status',o.status,'version',o.version);
  end if;
  if p_expected_version is null or o.version<>p_expected_version then raise exception '다른 화면에서 주문이 변경되었습니다. 새로고침해 주세요.'; end if;
  if not ((o.status='pending' and p_status in ('confirmed','cancelled')) or (o.status='confirmed' and p_status in ('shipped','cancelled')) or (o.status='shipped' and (p_status='delivered' or (o.product_id='hopungmi-5kg-pickup' and p_status='cancelled')))) then raise exception '변경할 수 없는 주문 상태입니다.'; end if;
  if p_status='shipped' and o.product_id<>'hopungmi-5kg-pickup' and btrim(coalesce(p_carrier,''))='' then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
  previous:=o.status;
  if p_status='confirmed' then delta:=-o.weight_grams;
  elsif p_status='cancelled' and (o.status='confirmed' or (o.product_id='hopungmi-5kg-pickup' and o.status='shipped')) then delta:=o.weight_grams; end if;
  if delta<>0 then
    select available_grams into balance from public.farmer_inventory where id for update;
    if balance+delta<0 then raise exception '재고가 부족해 주문을 확정할 수 없습니다.'; end if;
    update public.farmer_inventory set available_grams=balance+delta,version=version+1,updated_at=now() where id;
    insert into public.farmer_stock_events(delta_grams,balance_grams,reason,order_id,actor) values(delta,balance+delta,case when delta<0 then '주문 확정' else '배송 전 주문 취소' end,o.id,auth.uid());
  end if;
  update public.farmer_orders set status=p_status,version=version+1,updated_at=now(),
    confirmed_at=case when p_status='confirmed' then now() else confirmed_at end,
    shipped_at=case when p_status='shipped' then now() else shipped_at end,
    delivered_at=case when p_status='delivered' then now() else delivered_at end,
    cancelled_at=case when p_status='cancelled' then now() else cancelled_at end,
    carrier=case when p_status='shipped' then case when o.product_id='hopungmi-5kg-pickup' then '방문 수령' else btrim(p_carrier) end else carrier end,
    tracking_number=case when p_status='shipped' then case when o.product_id='hopungmi-5kg-pickup' then '' else btrim(coalesce(p_tracking_number,'')) end else tracking_number end
    where id=o.id returning * into o;
  insert into public.farmer_order_events(id,order_id,from_status,to_status,actor) values(p_request_id,o.id,previous,p_status,auth.uid());
  return jsonb_build_object('status',o.status,'version',o.version);
end $$;

create or replace function public.farmer_admin_order_list(p_status text default '',p_search text default '',p_offset integer default 0,p_kind text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb; count_all bigint;
begin
  perform farmer_private.require_admin();
  if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') then raise exception '조회 조건을 확인해 주세요.'; end if;
  select count(*) into count_all from public.farmer_orders o
    where (coalesce(p_status,'')='' or o.status=p_status) and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
    and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' GF-'||lpad(o.order_no::text,8,'0')))>0);
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb) into rows from (
    select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_id,case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end as fulfillment_method,o.product_name,o.quantity,o.weight_grams,o.total,o.discount_code,o.discount_amount,
      o.order_kind,o.batch_id,o.delivery_index,coalesce(nullif(o.recipient_name,''),o.customer_name) as recipient_name,
      coalesce(nullif(o.recipient_phone,''),o.phone) as recipient_phone,o.postal_code,o.customer_name,o.phone,o.address,o.address_detail,o.memo,
      o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version
    from public.farmer_orders o where (coalesce(p_status,'')='' or o.status=p_status) and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
      and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' GF-'||lpad(o.order_no::text,8,'0')))>0)
    order by o.created_at desc,o.id limit 50 offset p_offset
  )t;
  return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $$;

create or replace function public.farmer_lookup_orders(p_customer_name text,p_phone text,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
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
  select count(*) into count_value from public.farmer_orders where order_kind='sale' and customer_name=name_value and phone=phone_value;
  if count_value=0 then return jsonb_build_object('found',false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_number','GF-'||lpad(o.order_no::text,8,'0'),
    'product_name',o.product_name,'fulfillment_method',case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,'quantity',o.quantity,'subtotal',o.subtotal,
    'discount_amount',o.discount_amount,'shipping_fee',o.shipping_fee,'total',o.total,'status',o.status,
    'recipient_name',left(coalesce(nullif(o.recipient_name,''),o.customer_name),1)||repeat('*',least(3,greatest(1,length(coalesce(nullif(o.recipient_name,''),o.customer_name))-1))),
    'created_at',o.created_at,'delivered_at',o.delivered_at
  ) order by o.created_at desc,o.order_no desc),'[]'::jsonb) into rows
  from (select * from public.farmer_orders where order_kind='sale' and customer_name=name_value and phone=phone_value
        order by created_at desc,order_no desc limit 20 offset p_offset) o;
  next_value:=case when p_offset+20<count_value then p_offset+20 else null end;
  return jsonb_build_object('found',true,'orders',rows,'total_count',count_value,'next_offset',next_value);
end $$;

-- Keep public catalog/checkout access and private admin authorization unchanged.
revoke all on function public.farmer_catalog(),public.farmer_quote_batch(jsonb,text),public.farmer_submit_batch(uuid,text,text,jsonb,text,integer,boolean),public.farmer_submit_order(uuid,text,integer,text,text,text,text,text,text,integer,boolean),public.farmer_lookup_orders(text,text,integer) from public,anon,authenticated;
grant execute on function public.farmer_catalog(),public.farmer_quote_batch(jsonb,text),public.farmer_submit_batch(uuid,text,text,jsonb,text,integer,boolean),public.farmer_submit_order(uuid,text,integer,text,text,text,text,text,text,integer,boolean),public.farmer_lookup_orders(text,text,integer) to anon,authenticated;
revoke all on function public.farmer_admin_order_list(text,text,integer,text),public.farmer_admin_change_status(uuid,text,bigint,uuid,text,text) from public,anon,authenticated;
grant execute on function public.farmer_admin_order_list(text,text,integer,text),public.farmer_admin_change_status(uuid,text,bigint,uuid,text,text) to authenticated;
