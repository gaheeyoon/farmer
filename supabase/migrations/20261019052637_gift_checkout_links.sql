-- Private bearer links attach to canonical orders: income, stock and fulfillment
-- keep using farmer_orders. Confirming reserves stock; claiming never deducts twice.
create table farmer_private.gift_links (
 order_id uuid primary key references public.farmer_orders(id),
 token text not null unique check(token ~ '^[a-f0-9]{64}$'),
 sender_name text not null check(length(sender_name) between 1 and 40),
 recipient_label text not null check(length(recipient_label) between 1 and 40),
 message text not null default '' check(length(message)<=300),
 expires_at timestamptz, claimed_at timestamptz,
 claim_request_id uuid unique, claim_fingerprint text,
 created_at timestamptz not null default now()
);
alter table farmer_private.gift_links enable row level security;
revoke all on farmer_private.gift_links from public,anon,authenticated;

create function farmer_private.guard_gift_fulfillment() returns trigger
language plpgsql security definer set search_path='' as $$
declare g farmer_private.gift_links;
begin
 select * into g from farmer_private.gift_links where order_id=new.id for update;
 if found then
  if new.status in ('shipped','delivered') and g.claimed_at is null then
   raise exception '받는 분이 배송지를 등록한 뒤 발송할 수 있습니다.';
  end if;
  if old.status='pending' and new.status='confirmed' then
   update farmer_private.gift_links set expires_at=now()+interval '30 days' where order_id=new.id;
  end if;
 end if;
 return new;
end $$;
revoke all on function farmer_private.guard_gift_fulfillment() from public,anon,authenticated;
create trigger farmer_gift_shipping_guard before update of status on public.farmer_orders
for each row execute function farmer_private.guard_gift_fulfillment();

create function public.farmer_buy_gifts(p_request_id uuid,p_customer_name text,p_phone text,p_sender_name text,p_items jsonb,p_code text,p_expected_total integer,p_privacy_consent boolean)
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
 q:=public.farmer_quote_batch(p_items,p_code);
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

create function public.farmer_gift_view(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare g farmer_private.gift_links; o public.farmer_orders; state text;
begin
 if coalesce(p_token,'') !~ '^[a-f0-9]{64}$' then return jsonb_build_object('found',false); end if;
 select * into g from farmer_private.gift_links where token=p_token;
 if not found then return jsonb_build_object('found',false); end if;
 select * into o from public.farmer_orders where id=g.order_id;
 state:=case when o.status='cancelled' then 'cancelled' when g.claimed_at is not null then 'claimed' when o.status='pending' then 'pending' when g.expires_at<=now() then 'expired' else 'ready' end;
 return jsonb_build_object('found',true,'state',state,'sender_name',g.sender_name,'recipient_label',g.recipient_label,'message',g.message,'product_name',o.product_name,'quantity',o.quantity,'expires_at',g.expires_at,'delivery_status',case when state='claimed' then o.status else null end);
 -- Never return buyer contact, recipient contact, address, order ID or payment amounts.
end $$;

create function public.farmer_claim_gift(p_token text,p_request_id uuid,p_name text,p_phone text,p_postal_code text,p_address text,p_address_detail text,p_privacy_consent boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g farmer_private.gift_links; o public.farmer_orders; oid uuid; phone_value text; fp text;
begin
 if coalesce(p_token,'') !~ '^[a-f0-9]{64}$' or p_request_id is null then raise exception '선물 링크를 확인해 주세요.'; end if;
 if p_privacy_consent is distinct from true then raise exception '배송 정보 저장에 동의해 주세요.'; end if;
 phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
 if coalesce(length(btrim(p_name)),0) not between 1 and 40 or phone_value !~ '^0[0-9]{8,10}$' then raise exception '성함과 연락처를 확인해 주세요.'; end if;
 if coalesce(p_postal_code,'') !~ '^[0-9]{5}$' or coalesce(length(btrim(p_address)),0) not between 5 and 200 or length(coalesce(p_address_detail,''))>120 then raise exception '우편번호와 주소를 확인해 주세요.'; end if;
 select order_id into oid from farmer_private.gift_links where token=p_token;
 if not found then raise exception '선물 링크를 확인해 주세요.'; end if;
 -- Match the normal status-change lock order: order, link, inventory if needed.
 select * into o from public.farmer_orders where id=oid for update;
 select * into g from farmer_private.gift_links where order_id=oid for update;
 fp:=md5(jsonb_build_array(btrim(p_name),phone_value,p_postal_code,btrim(p_address),btrim(coalesce(p_address_detail,'')))::text);
 if g.claimed_at is not null then
  if g.claim_request_id=p_request_id and g.claim_fingerprint=fp then return jsonb_build_object('claimed',true); end if;
  raise exception '이미 배송지를 등록한 선물입니다.';
 end if;
 if o.status<>'confirmed' then raise exception '입금 확인이 완료된 선물만 받을 수 있습니다.'; end if;
 if g.expires_at is null or g.expires_at<=now() then raise exception '주소 등록 기한이 지났습니다. 판매자에게 문의해 주세요.'; end if;
 update farmer_private.gift_links set claimed_at=now(),claim_request_id=p_request_id,claim_fingerprint=fp where order_id=oid;
 update public.farmer_orders set recipient_name=btrim(p_name),recipient_phone=phone_value,postal_code=p_postal_code,address=btrim(p_address),address_detail=btrim(coalesce(p_address_detail,'')),version=version+1,updated_at=now() where id=oid;
 return jsonb_build_object('claimed',true);
end $$;

create function public.farmer_admin_create_gift_link(p_request_id uuid,p_product_id text,p_quantity integer,p_sender_name text,p_recipient_label text,p_message text,p_days integer default 30)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.farmer_products; o public.farmer_orders; fp text; previous farmer_private.order_batches; t text; balance bigint; result jsonb;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or coalesce(p_days,0) not between 1 and 90 or coalesce(p_quantity,0) not between 1 and 99 then raise exception '상품 수량과 유효기간을 확인해 주세요.'; end if;
 if coalesce(length(btrim(p_sender_name)),0) not between 1 and 40 or coalesce(length(btrim(p_recipient_label)),0) not between 1 and 40 or length(coalesce(p_message,''))>300 then raise exception '보내는 분, 받는 분과 메시지를 확인해 주세요.'; end if;
 fp:=md5(jsonb_build_array('free-gift-link',auth.uid(),p_product_id,p_quantity,p_sender_name,p_recipient_label,p_message,p_days)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.order_batches where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 select * into p from public.farmer_products where id=p_product_id and active and id<>'hopungmi-5kg-pickup';
 if not found then raise exception '택배 상품을 선택해 주세요.'; end if;
 select available_grams into balance from public.farmer_inventory where id for update;
 if balance<p.weight_grams::bigint*p_quantity then raise exception '남은 재고가 부족합니다.'; end if;
 insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_amount,shipping_fee,total,customer_name,phone,address,status,confirmed_at,order_kind,created_by,recipient_name,recipient_phone,postal_code)
 values(p_request_id,fp,p.id,p.name,p_quantity,p.weight_grams::bigint*p_quantity,0,0,0,0,0,btrim(p_sender_name),'','','confirmed',now(),'gift',auth.uid(),btrim(p_recipient_label),'','') returning * into o;
 t:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 insert into farmer_private.gift_links(order_id,token,sender_name,recipient_label,message,expires_at) values(o.id,t,btrim(p_sender_name),btrim(p_recipient_label),btrim(coalesce(p_message,'')),now()+p_days*interval '1 day');
 balance:=balance-o.weight_grams;
 update public.farmer_inventory set available_grams=balance,version=version+1,updated_at=now() where id;
 insert into public.farmer_stock_events(delta_grams,balance_grams,reason,order_id,actor) values(-o.weight_grams,balance,'선물 링크 재고 확보',o.id,auth.uid());
 insert into public.farmer_order_events(id,order_id,from_status,to_status,actor) values(gen_random_uuid(),o.id,'new','confirmed',auth.uid());
 result:=jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'token',t);
 insert into farmer_private.order_batches(request_id,fingerprint,receipt) values(p_request_id,fp,result);
 return result;
end $$;

create function public.farmer_admin_gift_links(p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 perform farmer_private.require_admin();
 if p_offset is null or p_offset<0 then raise exception '조회 조건을 확인해 주세요.'; end if;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]') into rows from (
 select o.id,o.version,o.created_at,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.order_kind,o.status,o.total,o.customer_name,o.phone,o.product_name,o.quantity,g.token,g.sender_name,g.recipient_label,g.message,g.expires_at,g.claimed_at,
 case when o.status='cancelled' then 'cancelled' when g.claimed_at is not null then 'claimed' when o.status='pending' then 'pending' when g.expires_at<=now() then 'expired' else 'ready' end as link_state
 from farmer_private.gift_links g join public.farmer_orders o on o.id=g.order_id order by o.created_at desc,o.id limit 50 offset p_offset)t;
 return jsonb_build_object('gifts',rows,'total',(select count(*) from farmer_private.gift_links),'reserved_kg',(select coalesce(sum(o.weight_grams),0)/1000.0 from farmer_private.gift_links g join public.farmer_orders o on o.id=g.order_id where o.status='confirmed' and g.claimed_at is null));
end $$;

create function public.farmer_admin_extend_gift(p_order_id uuid,p_days integer default 30) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.farmer_orders;
begin
 perform farmer_private.require_admin();
 if coalesce(p_days,0) not between 1 and 90 then raise exception '유효기간은 1~90일로 입력해 주세요.'; end if;
 select * into o from public.farmer_orders where id=p_order_id for update;
 if not found or o.status<>'confirmed' then raise exception '주소 등록 대기 선물만 연장할 수 있습니다.'; end if;
 update farmer_private.gift_links set expires_at=now()+p_days*interval '1 day' where order_id=o.id and claimed_at is null;
 if not found then raise exception '주소 등록 대기 선물이 아닙니다.'; end if;
 return jsonb_build_object('extended',true);
end $$;

revoke all on function public.farmer_buy_gifts(uuid,text,text,text,jsonb,text,integer,boolean),public.farmer_gift_view(text),public.farmer_claim_gift(text,uuid,text,text,text,text,text,boolean),public.farmer_admin_create_gift_link(uuid,text,integer,text,text,text,integer),public.farmer_admin_gift_links(integer),public.farmer_admin_extend_gift(uuid,integer) from public,anon,authenticated;
grant execute on function public.farmer_buy_gifts(uuid,text,text,text,jsonb,text,integer,boolean),public.farmer_gift_view(text),public.farmer_claim_gift(text,uuid,text,text,text,text,text,boolean) to anon,authenticated;
grant execute on function public.farmer_admin_create_gift_link(uuid,text,integer,text,text,text,integer),public.farmer_admin_gift_links(integer),public.farmer_admin_extend_gift(uuid,integer) to authenticated;

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
      exists(select 1 from farmer_private.gift_links g where g.order_id=o.id) as is_link_gift,exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null) as awaiting_address,o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version
    from public.farmer_orders o where (coalesce(p_status,'')='' or o.status=p_status) and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
      and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' GF-'||lpad(o.order_no::text,8,'0')))>0)
    order by o.created_at desc,o.id limit 50 offset p_offset
  )t;
  return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $$;

