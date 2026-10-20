-- Real free-gift attribution. Paid customer gifts keep their existing sale semantics.
alter table public.farmer_orders add column gift_sponsor text check(gift_sponsor in ('윤가희','홍세환'));
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
    if nullif(btrim(d->>'gift_sponsor'),'') is not null and btrim(d->>'gift_sponsor') not in ('윤가희','홍세환') then raise exception '선물하는 사람을 선택해 주세요.'; end if;
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
    line := jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',qty,'gift_sponsor',nullif(btrim(d->>'gift_sponsor'),''),
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
create or replace view farmer_private.admin_order_rows with(security_invoker=true) as
select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_id,case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end as fulfillment_method,o.product_name,o.quantity,o.weight_grams,o.unit_price,o.subtotal,o.shipping_fee,o.total,o.discount_code,o.discount_amount,
      o.order_kind,o.batch_id,o.delivery_index,coalesce(nullif(o.recipient_name,''),o.customer_name) as recipient_name,
      coalesce(nullif(o.recipient_phone,''),o.phone) as recipient_phone,o.postal_code,o.customer_name,o.phone,o.address,o.address_detail,o.memo,
      exists(select 1 from farmer_private.gift_links g where g.order_id=o.id) as is_link_gift,exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null) as awaiting_address,o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version,o.deleted_at,o.gift_sponsor
 from public.farmer_orders o;
create function public.farmer_admin_free_gift_summary(p_year integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;start_at timestamptz;end_at timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 then raise exception '조회 연도를 확인해 주세요.';end if;
 start_at:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');end_at:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with units as (
  select o.id,o.status,o.product_id,o.weight_grams/o.quantity as unit_grams,
   case when o.order_kind='gift' then o.quantity
    else least(o.quantity,floor(o.discount_amount::numeric/nullif(o.unit_price,0))::integer) end as free_boxes,
   case when o.order_kind='gift' then coalesce(o.gift_sponsor,case when g.sender_name in ('윤가희','홍세환') then g.sender_name end,'미지정')
    when o.discount_code='고구맙습니다홍세환선물용' then '홍세환' else '윤가희' end as sponsor
  from public.farmer_orders o left join farmer_private.gift_links g on g.order_id=o.id
  where o.deleted_at is null and o.status in ('pending','confirmed','shipped','delivered') and o.created_at>=start_at and o.created_at<end_at
   and ((o.order_kind='gift' and o.total=0) or (o.order_kind='sale' and o.discount_code in ('고구맙습니다홍세환선물용','고구맙습니다윤가희선물용') and o.unit_price>0 and o.discount_amount>=o.unit_price))
 ),gifts as (select * from units where free_boxes>0),
 people as (
  select n.sponsor,coalesce(sum(g.free_boxes),0) as boxes,coalesce(sum(g.free_boxes*g.unit_grams),0)/1000.0 as kg,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-5kg'),0) as qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-2kg'),0) as qty2,
   coalesce(sum(g.free_boxes) filter(where g.status='pending'),0) as pending_boxes
  from (values('윤가희',1),('홍세환',2),('미지정',3))n(sponsor,position) left join gifts g on g.sponsor=n.sponsor group by n.sponsor,n.position order by n.position
 )
 select jsonb_build_object('year',p_year,'totals',jsonb_build_object(
  'boxes',coalesce(sum(free_boxes),0),'kg',coalesce(sum(free_boxes*unit_grams),0)/1000.0,
  'qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg'),0),
  'qty2',coalesce(sum(free_boxes) filter(where product_id='hopungmi-2kg'),0),
  'pending_boxes',coalesce(sum(free_boxes) filter(where status='pending'),0),
  'reserved_boxes',coalesce(sum(free_boxes) filter(where status<>'pending'),0)),
  'people',(select jsonb_agg(to_jsonb(p)) from people p)) into result from gifts;
 return result;
end $$;
revoke all on function public.farmer_admin_free_gift_summary(integer) from public,anon,authenticated;
grant execute on function public.farmer_admin_free_gift_summary(integer) to authenticated;
