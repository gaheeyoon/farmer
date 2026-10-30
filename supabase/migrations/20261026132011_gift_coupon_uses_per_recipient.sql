-- Gift purchases consume one use per recipient/order; ordinary checkouts keep one use.
-- Derive counts from canonical orders so historical uses recalculate without changing money.
create function farmer_private.discount_checkout_uses(p_checkout_id uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select count(distinct case when g.order_id is not null then 'gift:'||o.id::text else 'checkout:'||p_checkout_id::text end)
 from public.farmer_orders o left join farmer_private.gift_links g on g.order_id=o.id
 where (o.batch_id=p_checkout_id or o.request_id=p_checkout_id)
  and o.status<>'cancelled' and o.deleted_at is null;
$$;
revoke all on function farmer_private.discount_checkout_uses(uuid) from public,anon,authenticated;

create or replace function farmer_private.discount_used(p_id uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(farmer_private.discount_checkout_uses(u.checkout_id)),0)::bigint
 from farmer_private.discount_usage u where u.code_id=p_id;
$$;

create function public.farmer_quote_gifts(p_deliveries jsonb,p_code text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare q jsonb;c farmer_private.discount_codes;uses integer;
begin
 q:=public.farmer_quote_batch(p_deliveries,p_code);
 if exists(select 1 from jsonb_array_elements(p_deliveries) d where d->>'product_id'='hopungmi-5kg-pickup') then
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
end $$;
revoke all on function public.farmer_quote_gifts(jsonb,text) from public,anon,authenticated;
grant execute on function public.farmer_quote_gifts(jsonb,text) to anon,authenticated;

create or replace function public.farmer_buy_gifts(p_request_id uuid,p_customer_name text,p_phone text,p_sender_name text,p_items jsonb,p_code text,p_expected_total integer,p_privacy_consent boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  if d->>'product_id'='hopungmi-5kg-pickup' then raise exception '선물은 택배 상품을 선택해 주세요.'; end if;
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
end $$;


create or replace function public.farmer_admin_discount_history(p_code_id uuid,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform farmer_private.require_admin();
 if p_code_id is null or p_offset is null or p_offset not between 0 and 1000000 then raise exception '조회 조건을 확인해 주세요.'; end if;
 with usage as (
  select u.*,farmer_private.discount_checkout_uses(u.checkout_id) as usage_count,farmer_private.discount_checkout_uses(u.checkout_id)=0 as released,
   (select jsonb_agg(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'discount_amount',o.discount_amount) order by o.delivery_index nulls first,o.order_no)
    from public.farmer_orders o where o.batch_id=u.checkout_id or o.request_id=u.checkout_id) as orders
  from farmer_private.discount_usage u where u.code_id=p_code_id
 ) select jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc,t.checkout_id)
  from (select * from usage order by created_at desc,checkout_id limit 50 offset p_offset)t),'[]'::jsonb),'total',(select count(*) from usage)) into result;
 return result;
end $$;
