-- Free administrative pickup gifts do not depend on public sale availability.
-- The public catalog and checkout continue to exclude the inactive pickup SKU.
create function public.farmer_admin_gift_catalog() returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform farmer_private.require_admin();
 select jsonb_build_object('products',coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'name',p.name,'weight_grams',p.weight_grams,'price',p.price,
  'fulfillment_method',case when p.id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,
  'available',(p.active or p.id='hopungmi-5kg-pickup') and i.available_grams>=p.weight_grams
 ) order by p.weight_grams,case when p.id='hopungmi-5kg-pickup' then 1 else 0 end,p.id),'[]'::jsonb))
 into result from public.farmer_products p cross join public.farmer_inventory i
 where i.id and (p.active or p.id in ('hopungmi-2kg','hopungmi-5kg-pickup'));
 return result;
end $$;
revoke all on function public.farmer_admin_gift_catalog() from public,anon,authenticated;
grant execute on function public.farmer_admin_gift_catalog() to authenticated;

create or replace function public.farmer_admin_create_gifts(p_request_id uuid,p_deliveries jsonb)
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
    if nullif(btrim(d->>'gift_sponsor'),'') is not null and btrim(d->>'gift_sponsor') not in ('윤가희','홍세환','윤가희&홍세환') then raise exception '선물하는 사람을 선택해 주세요.'; end if;
    qty := (d->>'quantity')::integer;
    if qty not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
    select * into p from public.farmer_products where id=d->>'product_id' and (active or id='hopungmi-5kg-pickup');
    if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
    if coalesce(length(btrim(d->>'recipient_name')),0) not between 1 and 40 then raise exception '%번째 받는 분 성함을 확인해 주세요.',idx; end if;
    phone_value:=regexp_replace(coalesce(d->>'recipient_phone',''),'[[:space:]()-]','','g');
    if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '%번째 받는 분 연락처를 확인해 주세요.',idx; end if;
    if p.id<>'hopungmi-5kg-pickup' then
      if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
      if coalesce(length(btrim(d->>'address')),0) not between 5 and 200 or length(coalesce(d->>'address_detail',''))>120 then raise exception '%번째 배송 정보를 확인해 주세요.',idx;end if;
    end if;
    if length(coalesce(d->>'memo',''))>300 then raise exception '%번째 배송 정보를 확인해 주세요.',idx;end if;
    line := jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',qty,'gift_sponsor',nullif(btrim(d->>'gift_sponsor'),''),
      'weight_grams',p.weight_grams::bigint*qty,'recipient_name',btrim(d->>'recipient_name'),
      'recipient_phone',phone_value,'postal_code',case when p.id='hopungmi-5kg-pickup' then '' else d->>'postal_code' end,
      'address',case when p.id='hopungmi-5kg-pickup' then '원북면 원이로 804-59' else btrim(d->>'address') end,
      'address_detail',case when p.id='hopungmi-5kg-pickup' then '홍세환 소셜라운지' else btrim(coalesce(d->>'address_detail','')) end,'memo',btrim(coalesce(d->>'memo','')));
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
      status,confirmed_at,order_kind,created_by,batch_id,delivery_index,gift_sponsor)
    values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,
      0,0,null,0,0,0,'어쩌다 농부','',line->>'recipient_name',line->>'recipient_phone',line->>'postal_code',
      line->>'address',line->>'address_detail',line->>'memo',null,'confirmed',now(),'gift',actor_id,p_request_id,idx,line->>'gift_sponsor')
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
