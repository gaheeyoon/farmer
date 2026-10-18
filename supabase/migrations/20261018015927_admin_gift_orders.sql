-- Gift orders are an admin-only allocation of stock, never a paid checkout.
alter table public.farmer_orders
  add column order_kind text not null default 'sale' check(order_kind in ('sale','gift')),
  add column created_by uuid,
  alter column privacy_consented_at drop not null;
alter table public.farmer_orders add constraint farmer_gift_no_charge check (
  order_kind <> 'gift' or (unit_price=0 and subtotal=0 and discount_amount=0
    and discount_code is null and shipping_fee=0 and total=0 and created_by is not null)
);
alter table public.farmer_orders add constraint farmer_sale_consent check (
  order_kind <> 'sale' or privacy_consented_at is not null
);
create index farmer_orders_kind_created on public.farmer_orders(order_kind,created_at desc,id);

create function public.farmer_admin_create_gifts(p_request_id uuid,p_deliveries jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
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
    qty := (d->>'quantity')::integer;
    if qty not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
    select * into p from public.farmer_products where id=d->>'product_id' and active;
    if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
    if coalesce(length(btrim(d->>'recipient_name')),0) not between 1 and 40 then raise exception '%번째 받는 분 성함을 확인해 주세요.',idx; end if;
    phone_value:=regexp_replace(coalesce(d->>'recipient_phone',''),'[[:space:]()-]','','g');
    if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '%번째 받는 분 연락처를 확인해 주세요.',idx; end if;
    if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
    if coalesce(length(btrim(d->>'address')),0) not between 5 and 200
      or length(coalesce(d->>'address_detail',''))>120 or length(coalesce(d->>'memo',''))>300 then
      raise exception '%번째 배송 정보를 확인해 주세요.',idx;
    end if;
    line := jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',qty,
      'weight_grams',p.weight_grams::bigint*qty,'recipient_name',btrim(d->>'recipient_name'),
      'recipient_phone',phone_value,'postal_code',d->>'postal_code','address',btrim(d->>'address'),
      'address_detail',btrim(coalesce(d->>'address_detail','')),'memo',btrim(coalesce(d->>'memo','')));
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
      status,confirmed_at,order_kind,created_by,batch_id,delivery_index)
    values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,
      0,0,null,0,0,0,'어쩌다 농부','',line->>'recipient_name',line->>'recipient_phone',line->>'postal_code',
      line->>'address',line->>'address_detail',line->>'memo',null,'confirmed',now(),'gift',actor_id,p_request_id,idx)
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
end $$;
revoke all on function public.farmer_admin_create_gifts(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.farmer_admin_create_gifts(uuid,jsonb) to authenticated;

-- Keep the original three-argument endpoint compatible for older admin tabs.
create function public.farmer_admin_order_list(p_status text default '',p_search text default '',p_offset integer default 0,p_kind text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb; count_all bigint;
begin
  perform farmer_private.require_admin();
  if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') then raise exception '조회 조건을 확인해 주세요.'; end if;
  select count(*) into count_all from public.farmer_orders o
    where (coalesce(p_status,'')='' or o.status=p_status) and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
    and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' GF-'||lpad(o.order_no::text,8,'0')))>0);
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb) into rows from (
    select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_name,o.quantity,o.weight_grams,o.total,o.discount_code,o.discount_amount,
      o.order_kind,o.batch_id,o.delivery_index,coalesce(nullif(o.recipient_name,''),o.customer_name) as recipient_name,
      coalesce(nullif(o.recipient_phone,''),o.phone) as recipient_phone,o.postal_code,o.customer_name,o.phone,o.address,o.address_detail,o.memo,
      o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version
    from public.farmer_orders o where (coalesce(p_status,'')='' or o.status=p_status) and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
      and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' GF-'||lpad(o.order_no::text,8,'0')))>0)
    order by o.created_at desc,o.id limit 50 offset p_offset
  )t;
  return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $$;
revoke all on function public.farmer_admin_order_list(text,text,integer,text) from public,anon,authenticated;
grant execute on function public.farmer_admin_order_list(text,text,integer,text) to authenticated;
create or replace function public.farmer_admin_orders(p_status text default '',p_search text default '',p_offset integer default 0) returns jsonb
language sql security definer set search_path='' as $$
  select public.farmer_admin_order_list(p_status,p_search,p_offset,'');
$$;

-- Administrative gifts never appear in the public customer lookup.
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
    'product_name',o.product_name,'quantity',o.quantity,'subtotal',o.subtotal,
    'discount_amount',o.discount_amount,'shipping_fee',o.shipping_fee,'total',o.total,'status',o.status,
    'recipient_name',left(coalesce(nullif(o.recipient_name,''),o.customer_name),1)||repeat('*',least(3,greatest(1,length(coalesce(nullif(o.recipient_name,''),o.customer_name))-1))),
    'created_at',o.created_at,'delivered_at',o.delivered_at
  ) order by o.created_at desc,o.order_no desc),'[]'::jsonb) into rows
  from (select * from public.farmer_orders where order_kind='sale' and customer_name=name_value and phone=phone_value
        order by created_at desc,order_no desc limit 20 offset p_offset) o;
  next_value:=case when p_offset+20<count_value then p_offset+20 else null end;
  return jsonb_build_object('found',true,'orders',rows,'total_count',count_value,'next_offset',next_value);
end $$;
revoke all on function public.farmer_lookup_orders(text,text,integer) from public,anon,authenticated;
grant execute on function public.farmer_lookup_orders(text,text,integer) to anon,authenticated;
