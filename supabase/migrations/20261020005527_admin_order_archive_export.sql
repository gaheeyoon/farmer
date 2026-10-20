-- Keep stock, discount and gift history intact; deletion is reversible archival.
alter table public.farmer_orders add column deleted_at timestamptz;
alter table public.farmer_orders add constraint farmer_deleted_order_cancelled check(deleted_at is null or status='cancelled');
create table farmer_private.order_archive_requests(
 request_id uuid primary key,actor uuid not null,fingerprint text not null,response jsonb not null,created_at timestamptz not null default now()
);
alter table farmer_private.order_archive_requests enable row level security;
revoke all on farmer_private.order_archive_requests from public,anon,authenticated;
create view farmer_private.admin_order_rows with(security_invoker=true) as
select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_id,case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end as fulfillment_method,o.product_name,o.quantity,o.weight_grams,o.unit_price,o.subtotal,o.shipping_fee,o.total,o.discount_code,o.discount_amount,
      o.order_kind,o.batch_id,o.delivery_index,coalesce(nullif(o.recipient_name,''),o.customer_name) as recipient_name,
      coalesce(nullif(o.recipient_phone,''),o.phone) as recipient_phone,o.postal_code,o.customer_name,o.phone,o.address,o.address_detail,o.memo,
      exists(select 1 from farmer_private.gift_links g where g.order_id=o.id) as is_link_gift,exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null) as awaiting_address,o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version,o.deleted_at
 from public.farmer_orders o;
revoke all on farmer_private.admin_order_rows from public,anon,authenticated;
create function farmer_private.filtered_admin_orders(p_status text,p_search text,p_kind text)
returns setof farmer_private.admin_order_rows language sql stable set search_path='' as $$
 select o.* from farmer_private.admin_order_rows o
 where (case when p_status='deleted' then o.deleted_at is not null else o.deleted_at is null and (coalesce(p_status,'')='' or o.status=p_status) end)
 and (coalesce(p_kind,'')='' or o.order_kind=p_kind)
 and (coalesce(p_search,'')='' or position(lower(p_search) in lower(o.customer_name||' '||o.phone||' '||o.recipient_name||' '||o.recipient_phone||' '||o.order_number))>0);
$$;
revoke all on function farmer_private.filtered_admin_orders(text,text,text) from public,anon,authenticated;
create or replace function public.farmer_admin_order_list(p_status text default '',p_search text default '',p_offset integer default 0,p_kind text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;count_all bigint;
begin
 perform farmer_private.require_admin();
 if p_offset is null or p_offset<0 or length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','shipped','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 select count(*) into count_all from farmer_private.filtered_admin_orders(p_status,p_search,p_kind);
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb) into rows from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 50 offset p_offset)t;
 return jsonb_build_object('orders',rows,'total',count_all,'offset',p_offset,'limit',50);
end $$;
create function public.farmer_admin_export_orders(p_status text default '',p_search text default '',p_kind text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;count_all integer;
begin
 perform farmer_private.require_admin();
 if length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','shipped','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 -- One snapshot, bounded memory. Never silently truncate an export.
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]'::jsonb),count(*) into rows,count_all from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 10001)t;
 if count_all>10000 then raise exception '한 번에 10,000건까지 내려받을 수 있습니다. 검색 조건을 좁혀 주세요.';end if;
 return jsonb_build_object('orders',rows,'total',count_all,'exported_at',now());
end $$;
create function public.farmer_admin_archive_orders(p_orders jsonb,p_restore boolean,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb;o public.farmer_orders;fp text;prev farmer_private.order_archive_requests;receipt jsonb;restored_grams bigint:=0;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or p_restore is null or jsonb_typeof(p_orders) is distinct from 'array' then raise exception '주문을 선택해 주세요.';end if;
 if jsonb_array_length(p_orders) not between 1 and 50 then raise exception '한 번에 1~50건을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_orders) e where jsonb_typeof(e) is distinct from 'object' or e->>'order_id' is null or e->>'expected_version' is null)
 or (select count(distinct e->>'order_id') from jsonb_array_elements(p_orders)e)<>jsonb_array_length(p_orders) then raise exception '주문 선택 정보를 확인해 주세요.';end if;
 fp:=md5(jsonb_build_array(auth.uid(),p_restore,p_orders)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into prev from farmer_private.order_archive_requests where request_id=p_request_id;
 if found then
  if prev.actor<>auth.uid() or prev.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.';end if;
  return prev.response;
 end if;
 -- Lock all selected orders before touching inventory; an exception rolls back the batch.
 perform 1 from public.farmer_orders where id in(select (e->>'order_id')::uuid from jsonb_array_elements(p_orders)e) order by id for update;
 for item in select e from jsonb_array_elements(p_orders)e order by e->>'order_id' loop
  select * into o from public.farmer_orders where id=(item->>'order_id')::uuid for update;
  if not found then raise exception '주문을 찾을 수 없습니다.';end if;
  if o.version<>(item->>'expected_version')::bigint then raise exception '다른 화면에서 주문이 변경되었습니다. 새로고침해 주세요.';end if;
  if p_restore then
   if o.deleted_at is null then raise exception '삭제된 주문만 복원할 수 있습니다.';end if;
   update public.farmer_orders set deleted_at=null,version=version+1,updated_at=now() where id=o.id;
  else
   if o.deleted_at is not null then raise exception '이미 삭제된 주문입니다.';end if;
   if o.status not in ('pending','confirmed','cancelled') then raise exception '배송·수령이 시작되거나 완료된 주문은 삭제할 수 없습니다.';end if;
   if o.status<>'cancelled' then
    if o.status='confirmed' then restored_grams:=restored_grams+o.weight_grams;end if;
    perform public.farmer_admin_change_status(o.id,'cancelled',o.version,gen_random_uuid(),'','');
   end if;
   update public.farmer_orders set deleted_at=now(),version=version+1,updated_at=now() where id=o.id;
  end if;
 end loop;
 receipt:=jsonb_build_object('saved',true,'count',jsonb_array_length(p_orders),'restored',p_restore,'returned_kg',restored_grams/1000.0);
 insert into farmer_private.order_archive_requests(request_id,actor,fingerprint,response)values(p_request_id,auth.uid(),fp,receipt);
 return receipt;
end $$;
revoke all on function public.farmer_admin_order_list(text,text,integer,text),public.farmer_admin_export_orders(text,text,text),public.farmer_admin_archive_orders(jsonb,boolean,uuid) from public,anon,authenticated;
grant execute on function public.farmer_admin_order_list(text,text,integer,text),public.farmer_admin_export_orders(text,text,text),public.farmer_admin_archive_orders(jsonb,boolean,uuid) to authenticated;

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
  select count(*) into count_value from public.farmer_orders where deleted_at is null and order_kind='sale' and customer_name=name_value and phone=phone_value;
  if count_value=0 then return jsonb_build_object('found',false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_number','GF-'||lpad(o.order_no::text,8,'0'),
    'product_name',o.product_name,'fulfillment_method',case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,'quantity',o.quantity,'subtotal',o.subtotal,
    'discount_amount',o.discount_amount,'shipping_fee',o.shipping_fee,'total',o.total,'status',o.status,
    'recipient_name',left(coalesce(nullif(o.recipient_name,''),o.customer_name),1)||repeat('*',least(3,greatest(1,length(coalesce(nullif(o.recipient_name,''),o.customer_name))-1))),
    'created_at',o.created_at,'delivered_at',o.delivered_at
  ) order by o.created_at desc,o.order_no desc),'[]'::jsonb) into rows
  from (select * from public.farmer_orders where deleted_at is null and order_kind='sale' and customer_name=name_value and phone=phone_value
        order by created_at desc,order_no desc limit 20 offset p_offset) o;
  next_value:=case when p_offset+20<count_value then p_offset+20 else null end;
  return jsonb_build_object('found',true,'orders',rows,'total_count',count_value,'next_offset',next_value);
end $$;

create or replace function public.farmer_lookup_gifts(p_customer_name text,p_phone text,p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
declare name_value text; phone_value text; attempts_value integer; window_value timestamptz;
 rows jsonb; count_value bigint;
begin
 if length(coalesce(p_customer_name,''))>40 or length(coalesce(p_phone,''))>40
    or p_offset is null or p_offset<0 or p_offset>100000 then return jsonb_build_object('found',false); end if;
 name_value:=btrim(coalesce(p_customer_name,''));
 phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
 if length(name_value)=0 or phone_value !~ '^0[0-9]{8,10}$' then return jsonb_build_object('found',false); end if;
 -- Share the existing phone limit across order and gift receipt lookups.
 delete from farmer_private.order_lookup_limits where window_started<now()-interval '1 day';
 insert into farmer_private.order_lookup_limits(bucket) values('phone:'||md5(phone_value))
 on conflict(bucket) do update set
  attempts=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then 1 else least(order_lookup_limits.attempts+1,100000) end,
  window_started=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then now() else order_lookup_limits.window_started end
 returning attempts,window_started into attempts_value,window_value;
 if attempts_value>20 then return jsonb_build_object('found',false,'retry_after',greatest(1,ceil(extract(epoch from window_value+interval '15 minutes'-now()))::integer)); end if;
 select count(*) into count_value from public.farmer_orders o join farmer_private.gift_links g on g.order_id=o.id
 where o.deleted_at is null and o.customer_name=name_value and o.phone=phone_value and o.order_kind='sale';
 if count_value=0 then return jsonb_build_object('found',false); end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'order_number','GF-'||lpad(x.order_no::text,8,'0'),'product_name',x.product_name,'quantity',x.quantity,
  'subtotal',x.subtotal,'discount_amount',x.discount_amount,'total',x.total,'status',x.status,
  'state',case when x.status='cancelled' then 'cancelled' when x.claimed_at is not null then 'claimed' when x.status='pending' then 'pending' when x.expires_at<=now() then 'expired' else 'ready' end,
  'recipient_label',left(x.recipient_label,1)||repeat('*',least(3,greatest(1,length(x.recipient_label)-1))),
  'created_at',x.created_at,'expires_at',x.expires_at,'claimed_at',x.claimed_at,'delivered_at',x.delivered_at
 ) order by x.created_at desc,x.order_no desc),'[]'::jsonb) into rows
 from (select o.*,g.recipient_label,g.expires_at,g.claimed_at from public.farmer_orders o join farmer_private.gift_links g on g.order_id=o.id
  where o.deleted_at is null and o.customer_name=name_value and o.phone=phone_value and o.order_kind='sale'
  order by o.created_at desc,o.order_no desc limit 20 offset p_offset) x;
 return jsonb_build_object('found',true,'gifts',rows,'total_count',count_value,'next_offset',case when p_offset+20<count_value then p_offset+20 else null end);
end $$;

create or replace function public.farmer_admin_gift_links(p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 perform farmer_private.require_admin();
 if p_offset is null or p_offset<0 then raise exception '조회 조건을 확인해 주세요.'; end if;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id),'[]') into rows from (
 select o.id,o.version,o.created_at,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.order_kind,o.status,o.total,o.customer_name,o.phone,o.product_name,o.quantity,g.token,g.sender_name,g.recipient_label,g.message,g.expires_at,g.claimed_at,
 case when o.status='cancelled' then 'cancelled' when g.claimed_at is not null then 'claimed' when o.status='pending' then 'pending' when g.expires_at<=now() then 'expired' else 'ready' end as link_state
 from farmer_private.gift_links g join public.farmer_orders o on o.id=g.order_id where o.deleted_at is null order by o.created_at desc,o.id limit 50 offset p_offset)t;
 return jsonb_build_object('gifts',rows,'total',(select count(*) from farmer_private.gift_links g join public.farmer_orders o on o.id=g.order_id where o.deleted_at is null),'reserved_kg',(select coalesce(sum(o.weight_grams),0)/1000.0 from farmer_private.gift_links g join public.farmer_orders o on o.id=g.order_id where o.status='confirmed' and g.claimed_at is null));
end $$;
