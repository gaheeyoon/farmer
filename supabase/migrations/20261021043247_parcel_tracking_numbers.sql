-- One order remains one inventory/payment record; parcel slots are indexed by box.
alter table public.farmer_orders add column tracking_numbers text[] not null default '{}';
update public.farmer_orders set tracking_numbers=array[tracking_number] where tracking_number<>'' and product_id<>'hopungmi-5kg-pickup';
alter table public.farmer_orders add constraint farmer_tracking_box_count check(cardinality(tracking_numbers)<=quantity);
alter table public.farmer_order_events add column request_fingerprint text;

create function farmer_private.parcel_tracking_numbers(p_text text,p_quantity integer)
returns text[] language plpgsql immutable set search_path='' as $$
declare values_json jsonb; result text[];
begin
 if length(coalesce(p_text,''))>15000 then raise exception '상자별 송장번호를 확인해 주세요.'; end if;
 if left(btrim(coalesce(p_text,'')),1)='[' then
  begin values_json:=p_text::jsonb; exception when others then raise exception '상자별 송장번호 형식을 확인해 주세요.'; end;
  if jsonb_typeof(values_json) is distinct from 'array' then raise exception '상자별 송장번호를 확인해 주세요.'; end if;
  if jsonb_array_length(values_json)>p_quantity or exists(select 1 from jsonb_array_elements(values_json) x where jsonb_typeof(x)<>'string') then raise exception '송장번호는 주문한 상자 수만큼 입력해 주세요.'; end if;
  select coalesce(array_agg(btrim(value) order by ord),'{}') into result from jsonb_array_elements_text(values_json) with ordinality x(value,ord);
 else result:=case when btrim(coalesce(p_text,''))='' then '{}'::text[] else array[btrim(p_text)] end;
 end if;
 if exists(select 1 from unnest(result) x where length(x)>100 or x ~ '[[:cntrl:]]') then raise exception '송장번호는 상자당 100자 이내로 입력해 주세요.'; end if;
 if (select count(*) from unnest(result) x where x<>'')<>(select count(distinct x) from unnest(result) x where x<>'') then raise exception '같은 주문의 송장번호가 중복되었습니다. 상자마다 다른 번호를 입력해 주세요.'; end if;
 return result;
end $$;
revoke all on function farmer_private.parcel_tracking_numbers(text,integer) from public,anon,authenticated;

create or replace function public.farmer_admin_change_status(p_order_id uuid,p_status text,p_expected_version bigint,p_request_id uuid,p_carrier text default '',p_tracking_number text default '') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.farmer_orders; balance bigint; delta bigint:=0; previous text; old_event public.farmer_order_events; parcels text[]; fingerprint text;
begin
  perform farmer_private.require_admin();
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  if length(coalesce(p_carrier,''))>60 or length(coalesce(p_tracking_number,''))>15000 then raise exception '배송 정보를 확인해 주세요.'; end if;
  select * into o from public.farmer_orders where id=p_order_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  fingerprint:=md5(jsonb_build_array(auth.uid(),p_order_id,p_status,p_expected_version,p_carrier,p_tracking_number)::text);
  select * into old_event from public.farmer_order_events where id=p_request_id;
  if found then
    if old_event.order_id<>p_order_id or old_event.to_status<>p_status or (old_event.request_fingerprint is not null and old_event.request_fingerprint<>fingerprint) then raise exception '이미 사용한 요청 번호입니다.'; end if;
    return jsonb_build_object('status',o.status,'version',o.version);
  end if;
  if p_expected_version is null or o.version<>p_expected_version then raise exception '다른 화면에서 주문이 변경되었습니다. 새로고침해 주세요.'; end if;
  if not ((o.status='pending' and p_status in ('confirmed','cancelled')) or (o.status='confirmed' and p_status in ('shipped','cancelled')) or (o.status='shipped' and (p_status='delivered' or (o.product_id='hopungmi-5kg-pickup' and p_status='cancelled')))) then raise exception '변경할 수 없는 주문 상태입니다.'; end if;
  if p_status='shipped' and o.product_id<>'hopungmi-5kg-pickup' and btrim(coalesce(p_carrier,''))='' then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
  if p_status='shipped' and o.product_id<>'hopungmi-5kg-pickup' then
    parcels:=farmer_private.parcel_tracking_numbers(p_tracking_number,o.quantity);
    if left(btrim(coalesce(p_tracking_number,'')),1)<>'[' and btrim(coalesce(p_tracking_number,''))=o.tracking_number and cardinality(o.tracking_numbers)>1 then parcels:=o.tracking_numbers; end if;
  else parcels:='{}'; end if;
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
    tracking_number=case when p_status='shipped' then case when o.product_id='hopungmi-5kg-pickup' then '' else coalesce((select n from unnest(parcels) with ordinality t(n,i) where n<>'' order by i limit 1),'') end else tracking_number end,
    tracking_numbers=case when p_status='shipped' then parcels else tracking_numbers end
    where id=o.id returning * into o;
  insert into public.farmer_order_events(id,order_id,from_status,to_status,actor,request_fingerprint) values(p_request_id,o.id,previous,p_status,auth.uid(),fingerprint);
  return jsonb_build_object('status',o.status,'version',o.version);
end $$;


create or replace function public.farmer_admin_update_delivery(p_order_id uuid,p_expected_version bigint,p_request_id uuid,p_delivery jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.farmer_orders; g farmer_private.gift_links; previous farmer_private.delivery_edit_requests;
 actor_id uuid:=auth.uid(); d jsonb; fp text; has_link boolean; changes text[]; parcels text[];
begin
 perform farmer_private.require_admin();
 if p_order_id is null or p_request_id is null or p_expected_version is null or p_expected_version<1
   or jsonb_typeof(p_delivery) is distinct from 'object' or length(p_delivery::text)>20000 then raise exception '수정할 배송 정보를 확인해 주세요.'; end if;
 if exists(select 1 from jsonb_each(p_delivery) e where jsonb_typeof(e.value)<>'string') then raise exception '배송 정보 형식을 확인해 주세요.'; end if;
 if exists(select 1 from jsonb_object_keys(p_delivery) k where k not in ('recipient_name','recipient_phone','postal_code','address','address_detail','memo','carrier','tracking_number')) then
  raise exception '배송 정보에 수정할 수 없는 항목이 있습니다.';
 end if;
 d:=jsonb_build_object(
  'recipient_name',btrim(coalesce(p_delivery->>'recipient_name','')),
  'recipient_phone',regexp_replace(coalesce(p_delivery->>'recipient_phone',''),'[[:space:]()-]','','g'),
  'postal_code',btrim(coalesce(p_delivery->>'postal_code','')),
  'address',btrim(coalesce(p_delivery->>'address','')),
  'address_detail',btrim(coalesce(p_delivery->>'address_detail','')),
  'memo',btrim(coalesce(p_delivery->>'memo','')),
  'carrier',btrim(coalesce(p_delivery->>'carrier','')),
  'tracking_number',btrim(coalesce(p_delivery->>'tracking_number',''))
 );
 if length(d->>'recipient_name') not between 1 and 40 or d->>'recipient_phone' !~ '^0[0-9]{8,10}$'
  or length(d->>'postal_code')>5 or length(d->>'address')>200 or length(d->>'address_detail')>120
  or length(d->>'memo')>300 or length(d->>'carrier')>60 or length(d->>'tracking_number')>15000 then raise exception '받는 분과 배송 정보를 확인해 주세요.'; end if;
 fp:=md5(jsonb_build_array(actor_id,p_order_id,p_expected_version,d)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.delivery_edit_requests where request_id=p_request_id;
 if found then
  if previous.actor<>actor_id or previous.order_id<>p_order_id or previous.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return jsonb_build_object('saved',true,'version',previous.order_version);
 end if;
 -- Use the same order -> gift lock order as recipient claim/status changes.
 select * into o from public.farmer_orders where id=p_order_id for update;
 if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
 if o.version<>p_expected_version then raise exception '다른 화면에서 주문이 변경되었습니다. 닫은 뒤 새로고침하고 다시 수정해 주세요.'; end if;
 select * into g from farmer_private.gift_links where order_id=o.id for update;has_link:=found;
 if has_link and g.claimed_at is null and o.status<>'confirmed' then raise exception '배송지가 등록되지 않은 선물은 입금 확인 후 수정해 주세요.'; end if;
 if o.product_id='hopungmi-5kg-pickup' then
  -- A delivery edit must never turn pickup into shipping or change its location.
  d:=d||jsonb_build_object('postal_code',o.postal_code,'address',o.address,'address_detail',o.address_detail,'carrier',o.carrier,'tracking_number',o.tracking_number,'tracking_numbers',to_jsonb(o.tracking_numbers));
 else
  parcels:=farmer_private.parcel_tracking_numbers(d->>'tracking_number',o.quantity);
  if left(d->>'tracking_number',1)<>'[' and d->>'tracking_number'=o.tracking_number and cardinality(o.tracking_numbers)>1 then parcels:=o.tracking_numbers; end if;
  d:=d||jsonb_build_object('tracking_numbers',to_jsonb(parcels),'tracking_number',coalesce((select n from unnest(parcels) with ordinality t(n,i) where n<>'' order by i limit 1),''));
  if d->>'postal_code' !~ '^[0-9]{5}$' or length(d->>'address')<5 then raise exception '우편번호와 주소를 확인해 주세요.'; end if;
  if o.status in ('shipped','delivered') and length(d->>'carrier')=0 then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
 end if;
 select coalesce(array_agg(k),'{}'::text[]) into changes from jsonb_object_keys(d) k where d->>k is distinct from to_jsonb(o)->>k;
 update public.farmer_orders set
  recipient_name=d->>'recipient_name',recipient_phone=d->>'recipient_phone',postal_code=d->>'postal_code',
  address=d->>'address',address_detail=d->>'address_detail',memo=d->>'memo',carrier=d->>'carrier',tracking_number=d->>'tracking_number',
  tracking_numbers=array(select jsonb_array_elements_text(d->'tracking_numbers')),
  version=version+1,updated_at=now() where id=o.id returning * into o;
 if has_link and g.claimed_at is null then
  update farmer_private.gift_links set claimed_at=now(),claim_request_id=p_request_id,
   claim_fingerprint=md5(jsonb_build_array(o.recipient_name,o.recipient_phone,o.postal_code,o.address,o.address_detail)::text)
  where order_id=o.id;
 end if;
 insert into farmer_private.delivery_edit_requests(request_id,order_id,actor,fingerprint,order_version,changed_fields)
 values(p_request_id,o.id,actor_id,fp,o.version,changes);
 return jsonb_build_object('saved',true,'version',o.version);
end $$;
revoke all on function public.farmer_admin_update_delivery(uuid,bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.farmer_admin_update_delivery(uuid,bigint,uuid,jsonb) to authenticated;

create or replace view farmer_private.admin_order_rows with(security_invoker=true) as
select o.id,'GF-'||lpad(o.order_no::text,8,'0') as order_number,o.product_id,case when o.product_id='hopungmi-5kg-pickup' then 'pickup' else 'shipping' end as fulfillment_method,o.product_name,o.quantity,o.weight_grams,o.unit_price,o.subtotal,o.shipping_fee,o.total,o.discount_code,o.discount_amount,
      o.order_kind,o.batch_id,o.delivery_index,coalesce(nullif(o.recipient_name,''),o.customer_name) as recipient_name,
      coalesce(nullif(o.recipient_phone,''),o.phone) as recipient_phone,o.postal_code,o.customer_name,o.phone,o.address,o.address_detail,o.memo,
      exists(select 1 from farmer_private.gift_links g where g.order_id=o.id) as is_link_gift,exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null) as awaiting_address,o.status,o.carrier,o.tracking_number,o.created_at,o.confirmed_at,o.shipped_at,o.delivered_at,o.cancelled_at,o.version,o.deleted_at,o.gift_sponsor,o.tracking_numbers
 from public.farmer_orders o;
revoke all on farmer_private.admin_order_rows from public,anon,authenticated;
