-- New quotes use percentage discounts; saved orders and their receipts retain their original amounts.
alter table farmer_private.discount_codes add column percent integer not null default 0 check (percent between 0 and 100);
update farmer_private.discount_codes set amount=0,percent=10 where code='GOGUMA';

create or replace function farmer_private.quote(p_product_id text,p_quantity integer,p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.farmer_products; discount integer:=0; rate integer:=0; v_code text:=upper(btrim(coalesce(p_code,''))); subtotal integer;
begin
  if p_quantity is null or p_quantity not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
  select * into p from public.farmer_products where id=p_product_id and active;
  if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
  subtotal:=p.price*p_quantity;
  if v_code<>'' then
    select amount,percent into discount,rate from farmer_private.discount_codes where discount_codes.code=v_code and active;
    if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
  end if;
  discount:=least(subtotal,case when rate>0 then floor(subtotal::numeric*rate/100)::integer else discount end);
  return jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',p_quantity,'weight_grams',p.weight_grams*p_quantity,
    'unit_price',p.price,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,'discount_percent',rate,'shipping_fee',3500,'total',subtotal-discount+3500);
end $$;

create or replace function public.farmer_quote_batch(p_deliveries jsonb,p_code text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb; q jsonb; lines jsonb:='[]'; subtotal integer:=0; discount integer:=0; shipping integer:=0; weight bigint:=0; idx integer:=0; rate integer:=0;
begin
 if jsonb_typeof(p_deliveries) is distinct from 'array' then raise exception '배송지를 추가해 주세요.'; end if;
 if jsonb_array_length(p_deliveries) not between 1 and 20 then raise exception '배송지는 한 번에 1~20곳까지 신청할 수 있습니다.'; end if;
 if length(coalesce(p_code,''))>40 then raise exception '할인코드를 확인해 주세요.'; end if;
 for item in select value from jsonb_array_elements(p_deliveries) loop
  idx:=idx+1;
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception '상품과 수량을 확인해 주세요.'; end if;
  q:=farmer_private.quote(item->>'product_id',(item->>'quantity')::integer,case when idx=1 or rate>0 then p_code else '' end);
  if idx=1 then rate:=coalesce((q->>'discount_percent')::integer,0); end if;
  lines:=lines||jsonb_build_array(q);subtotal:=subtotal+(q->>'subtotal')::integer;
  discount:=discount+(q->>'discount_amount')::integer;shipping:=shipping+(q->>'shipping_fee')::integer;weight:=weight+(q->>'weight_grams')::bigint;
 end loop;
 return jsonb_build_object('deliveries',lines,'subtotal',subtotal,'discount_code',lines->0->'discount_code','discount_amount',discount,'discount_percent',rate,'shipping_fee',shipping,'weight_grams',weight,'total',subtotal-discount+shipping);
end $$;

create or replace function public.farmer_submit_batch(p_request_id uuid,p_customer_name text,p_phone text,p_deliveries jsonb,p_coupon_code text,p_expected_total integer,p_privacy_consent boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare fingerprint text; previous farmer_private.order_batches; q jsonb; d jsonb; line jsonb; receipt jsonb; receipts jsonb:='[]'; idx integer:=0; order_request uuid; phone_value text; stock bigint;
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
 q:=public.farmer_quote_batch(p_deliveries,p_coupon_code);
 if p_expected_total is null or p_expected_total<>(q->>'total')::integer then raise exception '판매 금액이 변경되었습니다. 주문서를 다시 확인해 주세요.'; end if;
 select available_grams into stock from public.farmer_inventory where id;
 if stock<(q->>'weight_grams')::bigint then raise exception '전체 주문 수량에 비해 재고가 부족합니다. 수량을 줄여 주세요.'; end if;
 for d in select value from jsonb_array_elements(p_deliveries) loop
  idx:=idx+1;line:=q->'deliveries'->(idx-1);
  if coalesce(length(btrim(d->>'recipient_name')),0) not between 1 and 40 then raise exception '%번째 받는 분 성함을 확인해 주세요.',idx; end if;
  phone_value:=regexp_replace(coalesce(d->>'recipient_phone',''),'[[:space:]()-]','','g');
  if phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then raise exception '%번째 받는 분 연락처를 확인해 주세요.',idx; end if;
  if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
  order_request:=gen_random_uuid();
  receipt:=public.farmer_submit_order(order_request,d->>'product_id',(d->>'quantity')::integer,coalesce(line->>'discount_code',''),p_customer_name,p_phone,d->>'address',d->>'address_detail',d->>'memo',(line->>'total')::integer,true);
  update public.farmer_orders set batch_id=p_request_id,delivery_index=idx,recipient_name=btrim(d->>'recipient_name'),recipient_phone=phone_value,postal_code=d->>'postal_code' where request_id=order_request;
  receipts:=receipts||jsonb_build_array(receipt||jsonb_build_object('delivery_index',idx));
 end loop;
 receipt:=jsonb_build_object('orders',receipts,'total',q->'total','created_at',now());
 insert into farmer_private.order_batches values(p_request_id,fingerprint,receipt,now());
 return receipt;
end $$;
