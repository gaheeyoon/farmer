-- Private coupon definitions and checkout-level usage. Existing order prices stay unchanged.
alter table farmer_private.discount_codes
 add column id uuid not null default gen_random_uuid() unique,
 add column mode text not null default 'fixed' check(mode in ('fixed','percent','product_unit')),
 add column product_id text references public.farmer_products(id),
 add column usage_limit integer check(usage_limit between 1 and 1000000),
 add column version bigint not null default 1,
 add column created_at timestamptz not null default now(),
 add column updated_at timestamptz not null default now(),
 add column deleted_at timestamptz;
update farmer_private.discount_codes set mode='percent' where percent>0;
create table farmer_private.discount_usage (
 checkout_id uuid primary key, code_id uuid not null references farmer_private.discount_codes(id),
 code text not null, discount_amount integer not null check(discount_amount>0), created_at timestamptz not null default now()
);
create index discount_usage_code on farmer_private.discount_usage(code_id,created_at desc,checkout_id);
create table farmer_private.discount_requests (
 request_id uuid primary key, fingerprint text not null, receipt jsonb not null, created_at timestamptz not null default now()
);
alter table farmer_private.discount_usage enable row level security;
alter table farmer_private.discount_requests enable row level security;
revoke all on farmer_private.discount_usage,farmer_private.discount_requests from public,anon,authenticated;
-- Preserve prior usage, grouped by checkout rather than recipient.
insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount,created_at)
 select coalesce(o.batch_id,o.request_id),c.id,c.code,sum(o.discount_amount)::integer,min(o.created_at)
 from public.farmer_orders o join farmer_private.discount_codes c on c.code=o.discount_code
 where o.order_kind='sale' and o.discount_amount>0 group by coalesce(o.batch_id,o.request_id),c.id,c.code;

create function farmer_private.discount_used(p_id uuid) returns bigint
language sql stable security definer set search_path='' as $$
 select count(*) from farmer_private.discount_usage u where u.code_id=p_id and exists(
  select 1 from public.farmer_orders o where (o.batch_id=u.checkout_id or o.request_id=u.checkout_id) and o.status<>'cancelled'
 );
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
  line:=jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',qty,'weight_grams',p.weight_grams*qty,
    'unit_price',p.price,'subtotal',p.price*qty,'discount_code',case when part>0 then v_code else null end,
    'discount_amount',part,'discount_percent',rate,'shipping_fee',0,'total',p.price*qty-part);
  lines:=lines||jsonb_build_array(line);subtotal:=subtotal+p.price*qty;discount:=discount+part;weight:=weight+p.weight_grams*qty;
 end loop;
 if v_code<>'' and c.mode='product_unit' and not eligible then raise exception '이 할인코드는 지정된 상품이 포함된 주문에 사용할 수 있습니다.'; end if;
 return jsonb_build_object('deliveries',lines,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,
 'discount_percent',rate,'shipping_fee',0,'weight_grams',weight,'total',subtotal-discount);
end $$;

create or replace function farmer_private.quote(p_product_id text,p_quantity integer,p_code text) returns jsonb
language sql security definer set search_path='' as $$
 select public.farmer_quote_batch(jsonb_build_array(jsonb_build_object('product_id',p_product_id,'quantity',p_quantity)),p_code)->'deliveries'->0;
$$;

-- Serialize the last coupon use with edits, deletion and other submissions.
create function farmer_private.lock_discount(p_code text) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if btrim(coalesce(p_code,''))='' then return null; end if;
 select id into result from farmer_private.discount_codes where code=upper(normalize(btrim(p_code),NFKC)) for update;
 if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
 return result;
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
  if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' then raise exception '%번째 우편번호를 확인해 주세요.',idx; end if;
  if coalesce(length(btrim(d->>'address')),0) not between 5 and 200 or length(coalesce(d->>'address_detail',''))>120 or length(coalesce(d->>'memo',''))>300 then raise exception '배송 정보를 확인해 주세요.'; end if;
  insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,address_detail,memo,batch_id,delivery_index,recipient_name,recipient_phone,postal_code)
  values(gen_random_uuid(),fingerprint,line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,(line->>'unit_price')::integer,(line->>'subtotal')::integer,line->>'discount_code',(line->>'discount_amount')::integer,0,(line->>'total')::integer,btrim(p_customer_name),phone_value,btrim(d->>'address'),btrim(coalesce(d->>'address_detail','')),btrim(coalesce(d->>'memo','')),p_request_id,idx,btrim(d->>'recipient_name'),recipient_phone_value,d->>'postal_code') returning * into o;
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
  if p_address is null or length(btrim(p_address)) not between 5 and 200 or length(coalesce(p_address_detail,''))>120 or length(coalesce(p_memo,''))>300 or length(coalesce(p_coupon_code,''))>40 then raise exception '배송 정보를 확인해 주세요.'; end if;
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
      values(p_request_id,fingerprint,p_product_id,q->>'product_name',p_quantity,(q->>'weight_grams')::bigint,(q->>'unit_price')::integer,(q->>'subtotal')::integer,q->>'discount_code',(q->>'discount_amount')::integer,(q->>'shipping_fee')::integer,(q->>'total')::integer,btrim(p_customer_name),phone_value,btrim(p_address),btrim(coalesce(p_address_detail,'')),btrim(coalesce(p_memo,''))) returning * into o;
    if coupon_id is not null and o.discount_amount>0 then
      insert into farmer_private.discount_usage(checkout_id,code_id,code,discount_amount) values(p_request_id,coupon_id,o.discount_code,o.discount_amount);
    end if;
  end if;
  return jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'total',o.total,'created_at',o.created_at);
end $$;

create function public.farmer_admin_discount_list(p_search text default '',p_status text default '',p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform farmer_private.require_admin();
 if length(coalesce(p_search,''))>100 or coalesce(p_status,'') not in ('','active','inactive','exhausted','deleted') or p_offset is null or p_offset not between 0 and 1000000 then raise exception '조회 조건을 확인해 주세요.'; end if;
 with codes as (
  select c.*,farmer_private.discount_used(c.id) as used_count,p.name as product_name,
  case when c.deleted_at is not null then 'deleted' when not c.active then 'inactive'
   when c.usage_limit is not null and farmer_private.discount_used(c.id)>=c.usage_limit then 'exhausted' else 'active' end as status
  from farmer_private.discount_codes c left join public.farmer_products p on p.id=c.product_id
 ), filtered as (
  select * from codes where (coalesce(p_search,'')='' or position(lower(p_search) in lower(code))>0)
   and ((coalesce(p_status,'')='' and deleted_at is null) or status=p_status)
 ) select jsonb_build_object('codes',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id) from
  (select * from filtered order by created_at desc,id limit 25 offset p_offset)t),'[]'::jsonb),
  'total',(select count(*) from filtered),'offset',p_offset,'limit',25,
  'products',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'price',price) order by weight_grams) from public.farmer_products where active)) into result;
 return result;
end $$;

create function public.farmer_admin_discount_history(p_code_id uuid,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform farmer_private.require_admin();
 if p_code_id is null or p_offset is null or p_offset not between 0 and 1000000 then raise exception '조회 조건을 확인해 주세요.'; end if;
 with usage as (
  select u.*,not exists(select 1 from public.farmer_orders o where (o.batch_id=u.checkout_id or o.request_id=u.checkout_id) and o.status<>'cancelled') as released,
   (select jsonb_agg(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'discount_amount',o.discount_amount) order by o.delivery_index nulls first,o.order_no)
    from public.farmer_orders o where o.batch_id=u.checkout_id or o.request_id=u.checkout_id) as orders
  from farmer_private.discount_usage u where u.code_id=p_code_id
 ) select jsonb_build_object('entries',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc,t.checkout_id)
  from (select * from usage order by created_at desc,checkout_id limit 50 offset p_offset)t),'[]'::jsonb),'total',(select count(*) from usage)) into result;
 return result;
end $$;

create function public.farmer_admin_discount_save(p_request_id uuid,p_entry jsonb,p_expected_version bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous farmer_private.discount_requests; c farmer_private.discount_codes; fingerprint text; receipt jsonb;
 entry_id uuid; name text; kind text; value integer; rate integer; lim integer; product text; enabled boolean; exists_entry boolean;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or jsonb_typeof(p_entry) is distinct from 'object' then raise exception '저장할 할인코드를 확인해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array('save',auth.uid(),p_entry,p_expected_version)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.discount_requests where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 if coalesce(p_entry->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  or jsonb_typeof(p_entry->'active') is distinct from 'boolean'
  or coalesce(p_entry->>'amount','') !~ '^[0-9]{1,9}$' or coalesce(p_entry->>'percent','') !~ '^[0-9]{1,3}$' then raise exception '코드명과 할인 설정을 확인해 주세요.'; end if;
 entry_id:=(p_entry->>'id')::uuid;name:=upper(normalize(btrim(coalesce(p_entry->>'code','')),NFKC));kind:=p_entry->>'mode';
 value:=(p_entry->>'amount')::integer;rate:=(p_entry->>'percent')::integer;enabled:=(p_entry->>'active')::boolean;
 product:=nullif(p_entry->>'product_id','');
 if length(name) not between 1 and 40 or name ~ '[[:cntrl:]]' or kind is null or kind not in ('fixed','percent','product_unit')
  or (kind='percent' and (rate not between 1 and 100 or value<>0))
  or (kind<>'percent' and (value not between 1 and 100000000 or rate<>0)) then raise exception '코드명과 할인 금액을 확인해 주세요.'; end if;
 if kind='product_unit' then
  if not exists(select 1 from public.farmer_products where id=product and active) then raise exception '대상 상품을 선택해 주세요.'; end if;
 else product:=null; end if;
 if nullif(p_entry->>'usage_limit','') is not null then
  if (p_entry->>'usage_limit') !~ '^[0-9]{1,7}$' then raise exception '발급 수량을 확인해 주세요.'; end if;
  lim:=(p_entry->>'usage_limit')::integer;
  if lim not between 1 and 1000000 then raise exception '발급 수량을 확인해 주세요.'; end if;
 end if;
 -- Serialize creation for the same normalized name as well as edits to the same row.
 perform pg_advisory_xact_lock(hashtextextended('discount-name:'||name,0));
 select * into c from farmer_private.discount_codes where id=entry_id for update;exists_entry:=found;
 if exists_entry then
  if c.deleted_at is not null or p_expected_version is null or c.version<>p_expected_version then raise exception '다른 화면에서 할인코드가 변경되었습니다. 새로고침해 주세요.'; end if;
  if lim is not null and lim<farmer_private.discount_used(c.id) then raise exception '이미 사용한 수량보다 적게 설정할 수 없습니다.'; end if;
 elsif p_expected_version is not null then raise exception '수정할 할인코드가 없습니다. 새로고침해 주세요.';
 end if;
 if exists(select 1 from farmer_private.discount_codes where code=name and id<>entry_id) then raise exception '이미 등록된 코드명입니다. 삭제된 코드명도 다시 사용할 수 없습니다.'; end if;
 if exists_entry then
  update farmer_private.discount_codes set code=name,amount=value,percent=rate,mode=kind,product_id=product,usage_limit=lim,active=enabled,version=version+1,updated_at=now() where id=entry_id returning * into c;
 else
  insert into farmer_private.discount_codes(id,code,amount,percent,mode,product_id,usage_limit,active) values(entry_id,name,value,rate,kind,product,lim,enabled) returning * into c;
 end if;
 receipt:=jsonb_build_object('id',c.id,'version',c.version,'deleted',false);
 insert into farmer_private.discount_requests values(p_request_id,fingerprint,receipt,now());
 return receipt;
end $$;

create function public.farmer_admin_discount_delete(p_entry_id uuid,p_expected_version bigint,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c farmer_private.discount_codes; previous farmer_private.discount_requests; fingerprint text; receipt jsonb;
begin
 perform farmer_private.require_admin();
 if p_entry_id is null or p_expected_version is null or p_request_id is null then raise exception '삭제할 할인코드를 확인해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array('delete',auth.uid(),p_entry_id,p_expected_version)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.discount_requests where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 select * into c from farmer_private.discount_codes where id=p_entry_id for update;
 if not found or c.deleted_at is not null or c.version<>p_expected_version then raise exception '다른 화면에서 할인코드가 변경되었습니다. 새로고침해 주세요.'; end if;
 update farmer_private.discount_codes set active=false,deleted_at=now(),updated_at=now(),version=version+1 where id=c.id returning * into c;
 receipt:=jsonb_build_object('id',c.id,'version',c.version,'deleted',true);
 insert into farmer_private.discount_requests values(p_request_id,fingerprint,receipt,now());
 return receipt;
end $$;
revoke all on function farmer_private.discount_used(uuid),farmer_private.lock_discount(text),farmer_private.quote(text,integer,text) from public,anon,authenticated;
revoke all on function public.farmer_admin_discount_list(text,text,integer),public.farmer_admin_discount_history(uuid,integer),public.farmer_admin_discount_save(uuid,jsonb,bigint),public.farmer_admin_discount_delete(uuid,bigint,uuid) from public,anon,authenticated;
grant execute on function public.farmer_admin_discount_list(text,text,integer),public.farmer_admin_discount_history(uuid,integer),public.farmer_admin_discount_save(uuid,jsonb,bigint),public.farmer_admin_discount_delete(uuid,bigint,uuid) to authenticated;
