-- Order data is private. Browsers can use only the explicitly granted RPCs.
create schema if not exists farmer_private;
revoke all on schema farmer_private from public, anon, authenticated;

create table if not exists farmer_private.admin_emails (
  email text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);
create table if not exists public.farmer_products (
  id text primary key, name text not null, weight_grams integer not null check(weight_grams > 0),
  price integer not null check(price >= 0), active boolean not null default true
);
insert into public.farmer_products values
 ('hopungmi-2kg','호풍미 혼합 2kg',2000,10000,true),
 ('hopungmi-5kg','호풍미 혼합 5kg',5000,20000,true)
on conflict (id) do nothing;
create table if not exists farmer_private.discount_codes (
  code text primary key, amount integer not null check(amount >= 0), active boolean not null default true
);
insert into farmer_private.discount_codes values ('GOGUMA',2000,true) on conflict(code) do nothing;
create table if not exists public.farmer_inventory (
  id boolean primary key default true check(id), available_grams bigint not null default 0 check(available_grams >= 0),
  version bigint not null default 1, updated_at timestamptz not null default now()
);
insert into public.farmer_inventory(id) values(true) on conflict do nothing;
create table if not exists public.farmer_orders (
  id uuid primary key default gen_random_uuid(), order_no bigint generated always as identity unique,
  request_id uuid not null unique, request_fingerprint text not null,
  product_id text not null references public.farmer_products(id), product_name text not null,
  quantity integer not null check(quantity between 1 and 99), weight_grams bigint not null check(weight_grams > 0),
  unit_price integer not null check(unit_price >= 0), subtotal integer not null,
  discount_code text, discount_amount integer not null default 0, shipping_fee integer not null default 3500,
  total integer not null check(total >= 0),
  customer_name text not null, phone text not null, address text not null, address_detail text not null default '', memo text not null default '',
  privacy_consented_at timestamptz not null default now(),
  status text not null default 'pending' check(status in ('pending','confirmed','shipped','delivered','cancelled')),
  carrier text not null default '', tracking_number text not null default '',
  confirmed_at timestamptz, shipped_at timestamptz, delivered_at timestamptz, cancelled_at timestamptz,
  version bigint not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists farmer_orders_status_created on public.farmer_orders(status,created_at desc);
create index if not exists farmer_orders_phone_created on public.farmer_orders(phone,created_at desc);
create table if not exists public.farmer_stock_events (
  id uuid primary key default gen_random_uuid(), request_id uuid unique,
  delta_grams bigint not null, balance_grams bigint not null check(balance_grams >= 0), reason text not null,
  order_id uuid references public.farmer_orders(id), actor uuid, created_at timestamptz not null default now()
);
create index if not exists farmer_stock_events_order on public.farmer_stock_events(order_id);
create table if not exists public.farmer_order_events (
  id uuid primary key, order_id uuid not null references public.farmer_orders(id),
  from_status text not null, to_status text not null, actor uuid, created_at timestamptz not null default now()
);
create index if not exists farmer_order_events_order on public.farmer_order_events(order_id);

alter table farmer_private.admin_emails enable row level security;
alter table farmer_private.discount_codes enable row level security;
alter table public.farmer_products enable row level security;
alter table public.farmer_inventory enable row level security;
alter table public.farmer_orders enable row level security;
alter table public.farmer_stock_events enable row level security;
alter table public.farmer_order_events enable row level security;
revoke all on public.farmer_products,public.farmer_inventory,public.farmer_orders,public.farmer_stock_events,public.farmer_order_events from public,anon,authenticated;
revoke all on all tables in schema farmer_private from public,anon,authenticated;
revoke all on sequence public.farmer_orders_order_no_seq from public,anon,authenticated;

create or replace function farmer_private.require_admin() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from auth.users u join farmer_private.admin_emails a on a.email=lower(u.email)
    where u.id=auth.uid() and u.email_confirmed_at is not null
  ) then raise exception '관리자 권한이 없습니다.' using errcode='42501'; end if;
end $$;

create or replace function farmer_private.quote(p_product_id text,p_quantity integer,p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.farmer_products; discount integer:=0; v_code text:=upper(btrim(coalesce(p_code,''))); subtotal integer;
begin
  if p_quantity is null or p_quantity not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
  select * into p from public.farmer_products where id=p_product_id and active;
  if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
  if v_code<>'' then
    select amount into discount from farmer_private.discount_codes where discount_codes.code=v_code and active;
    if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
  end if;
  subtotal:=p.price*p_quantity; discount:=least(subtotal,discount);
  return jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',p_quantity,'weight_grams',p.weight_grams*p_quantity,
    'unit_price',p.price,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,'shipping_fee',3500,'total',subtotal-discount+3500);
end $$;

create or replace function public.farmer_catalog() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('products',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'weight_grams',p.weight_grams,'price',p.price,'available',i.available_grams>=p.weight_grams) order by p.weight_grams),'[]'::jsonb) from public.farmer_products p cross join public.farmer_inventory i where p.active), 'shipping_fee',3500);
$$;
create or replace function public.farmer_quote(p_product_id text,p_quantity integer,p_code text default '') returns jsonb
language sql security definer set search_path = '' as $$ select farmer_private.quote(p_product_id,p_quantity,p_code); $$;

create or replace function public.farmer_submit_order(
 p_request_id uuid,p_product_id text,p_quantity integer,p_coupon_code text,p_customer_name text,p_phone text,
 p_address text,p_address_detail text,p_memo text,p_expected_total integer,p_privacy_consent boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare q jsonb; o public.farmer_orders; fingerprint text; phone_value text; stock bigint;
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
    q:=farmer_private.quote(p_product_id,p_quantity,p_coupon_code);
    if p_expected_total is null or (q->>'total')::integer<>p_expected_total then raise exception '판매 금액이 변경되었습니다. 새로고침 후 다시 확인해 주세요.'; end if;
    select available_grams into stock from public.farmer_inventory where id;
    if stock<(q->>'weight_grams')::bigint then raise exception '남은 재고가 부족합니다. 수량을 줄여 주세요.'; end if;
    -- Pending orders do not reserve stock. Stock is atomically deducted at confirmation.
    insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,address,address_detail,memo)
      values(p_request_id,fingerprint,p_product_id,q->>'product_name',p_quantity,(q->>'weight_grams')::bigint,(q->>'unit_price')::integer,(q->>'subtotal')::integer,q->>'discount_code',(q->>'discount_amount')::integer,(q->>'shipping_fee')::integer,(q->>'total')::integer,btrim(p_customer_name),phone_value,btrim(p_address),btrim(coalesce(p_address_detail,'')),btrim(coalesce(p_memo,''))) returning * into o;
  end if;
  return jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'status',o.status,'total',o.total,'created_at',o.created_at);
end $$;

create or replace function public.farmer_admin_summary() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare data jsonb;
begin
  perform farmer_private.require_admin();
  select jsonb_build_object('available_kg',i.available_grams/1000.0,'inventory_version',i.version,'inventory_updated_at',i.updated_at,
    'pending',(select count(*) from public.farmer_orders where status='pending'),
    'confirmed',(select count(*) from public.farmer_orders where status='confirmed'),
    'shipped',(select count(*) from public.farmer_orders where status='shipped'),
    'delivered',(select count(*) from public.farmer_orders where status='delivered')) into data from public.farmer_inventory i where id;
  return data;
end $$;

create or replace function public.farmer_admin_orders(p_status text default '',p_search text default '',p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare rows jsonb; count_all bigint;
begin
  perform farmer_private.require_admin();
  if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 then raise exception '조회 조건을 확인해 주세요.'; end if;
  select count(*) into count_all from public.farmer_orders o where (coalesce(p_status,'')='' or o.status=p_status)
    and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' GF-'||lpad(o.order_no::text,8,'0')))>0);
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]'::jsonb) into rows from (
    select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_name,o.quantity,o.weight_grams,o.total,o.discount_code,o.discount_amount,
      o.customer_name,o.phone,o.address,o.address_detail,o.memo,o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version
    from public.farmer_orders o where (coalesce(p_status,'')='' or o.status=p_status)
      and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' GF-'||lpad(o.order_no::text,8,'0')))>0)
    order by o.created_at desc,o.id limit 50 offset p_offset
  )t;
  return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
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
  if not ((o.status='pending' and p_status in ('confirmed','cancelled')) or (o.status='confirmed' and p_status in ('shipped','cancelled')) or (o.status='shipped' and p_status='delivered')) then raise exception '변경할 수 없는 주문 상태입니다.'; end if;
  if p_status='shipped' and btrim(coalesce(p_carrier,''))='' then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
  previous:=o.status;
  if p_status='confirmed' then delta:=-o.weight_grams;
  elsif p_status='cancelled' and o.status='confirmed' then delta:=o.weight_grams; end if;
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
    carrier=case when p_status='shipped' then btrim(p_carrier) else carrier end,
    tracking_number=case when p_status='shipped' then btrim(coalesce(p_tracking_number,'')) else tracking_number end
    where id=o.id returning * into o;
  insert into public.farmer_order_events(id,order_id,from_status,to_status,actor) values(p_request_id,o.id,previous,p_status,auth.uid());
  return jsonb_build_object('status',o.status,'version',o.version);
end $$;

create or replace function public.farmer_admin_adjust_stock(p_delta_kg numeric,p_reason text,p_expected_version bigint,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare i public.farmer_inventory; e public.farmer_stock_events; delta bigint;
begin
  perform farmer_private.require_admin();
  if p_request_id is null or p_delta_kg is null or p_delta_kg=0 or abs(p_delta_kg)>100000 or p_delta_kg<>round(p_delta_kg,3) then raise exception '재고 증감 kg를 소수 셋째 자리까지 입력해 주세요.'; end if;
  if p_reason is null or length(btrim(p_reason)) not between 2 and 200 then raise exception '재고 변경 사유를 입력해 주세요.'; end if;
  delta:=(p_delta_kg*1000)::bigint;
  select * into i from public.farmer_inventory where id for update;
  select * into e from public.farmer_stock_events where request_id=p_request_id;
  if found then
    if e.delta_grams<>delta or e.reason<>btrim(p_reason) then raise exception '이미 사용한 요청 번호입니다.'; end if;
    return jsonb_build_object('available_kg',i.available_grams/1000.0,'version',i.version);
  end if;
  if p_expected_version is null or i.version<>p_expected_version then raise exception '재고가 변경되었습니다. 새로고침한 뒤 다시 입력해 주세요.'; end if;
  if i.available_grams+delta<0 then raise exception '남은 재고보다 많이 차감할 수 없습니다.'; end if;
  update public.farmer_inventory set available_grams=available_grams+delta,version=version+1,updated_at=now() where id returning * into i;
  insert into public.farmer_stock_events(request_id,delta_grams,balance_grams,reason,actor) values(p_request_id,delta,i.available_grams,btrim(p_reason),auth.uid());
  return jsonb_build_object('available_kg',i.available_grams/1000.0,'version',i.version);
end $$;

create or replace function public.farmer_admin_stock_history() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare data jsonb;
begin
 perform farmer_private.require_admin();
 select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc),'[]'::jsonb) into data from (select delta_grams/1000.0 as delta_kg,balance_grams/1000.0 as balance_kg,reason,created_at from public.farmer_stock_events order by created_at desc limit 30)e;
 return data;
end $$;

revoke all on function farmer_private.require_admin(),farmer_private.quote(text,integer,text) from public,anon,authenticated;
revoke all on function public.farmer_catalog(),public.farmer_quote(text,integer,text),public.farmer_submit_order(uuid,text,integer,text,text,text,text,text,text,integer,boolean),public.farmer_admin_summary(),public.farmer_admin_orders(text,text,integer),public.farmer_admin_change_status(uuid,text,bigint,uuid,text,text),public.farmer_admin_adjust_stock(numeric,text,bigint,uuid),public.farmer_admin_stock_history() from public,anon,authenticated;
grant execute on function public.farmer_catalog(),public.farmer_quote(text,integer,text),public.farmer_submit_order(uuid,text,integer,text,text,text,text,text,text,integer,boolean) to anon,authenticated;
grant execute on function public.farmer_admin_summary(),public.farmer_admin_orders(text,text,integer),public.farmer_admin_change_status(uuid,text,bigint,uuid,text,text),public.farmer_admin_adjust_stock(numeric,text,bigint,uuid),public.farmer_admin_stock_history() to authenticated;
