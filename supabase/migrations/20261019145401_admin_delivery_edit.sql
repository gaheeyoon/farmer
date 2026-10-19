-- Private replay/audit metadata. No old/new addresses or phone numbers are duplicated here.
create table farmer_private.delivery_edit_requests (
 request_id uuid primary key,
 order_id uuid not null references public.farmer_orders(id),
 actor uuid not null, fingerprint text not null, order_version bigint not null,
 changed_fields text[] not null default '{}', created_at timestamptz not null default now()
);
alter table farmer_private.delivery_edit_requests enable row level security;
revoke all on farmer_private.delivery_edit_requests from public,anon,authenticated;

create function public.farmer_admin_update_delivery(p_order_id uuid,p_expected_version bigint,p_request_id uuid,p_delivery jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.farmer_orders; g farmer_private.gift_links; previous farmer_private.delivery_edit_requests;
 actor_id uuid:=auth.uid(); d jsonb; fp text; has_link boolean; changes text[];
begin
 perform farmer_private.require_admin();
 if p_order_id is null or p_request_id is null or p_expected_version is null or p_expected_version<1
   or jsonb_typeof(p_delivery) is distinct from 'object' or length(p_delivery::text)>4000 then raise exception '수정할 배송 정보를 확인해 주세요.'; end if;
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
  or length(d->>'memo')>300 or length(d->>'carrier')>60 or length(d->>'tracking_number')>100 then raise exception '받는 분과 배송 정보를 확인해 주세요.'; end if;
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
  d:=d||jsonb_build_object('postal_code',o.postal_code,'address',o.address,'address_detail',o.address_detail,'carrier',o.carrier,'tracking_number',o.tracking_number);
 else
  if d->>'postal_code' !~ '^[0-9]{5}$' or length(d->>'address')<5 then raise exception '우편번호와 주소를 확인해 주세요.'; end if;
  if o.status in ('shipped','delivered') and length(d->>'carrier')=0 then raise exception '택배사 또는 배송 방법을 입력해 주세요.'; end if;
 end if;
 select coalesce(array_agg(k),'{}'::text[]) into changes from jsonb_object_keys(d) k where d->>k is distinct from to_jsonb(o)->>k;
 update public.farmer_orders set
  recipient_name=d->>'recipient_name',recipient_phone=d->>'recipient_phone',postal_code=d->>'postal_code',
  address=d->>'address',address_detail=d->>'address_detail',memo=d->>'memo',carrier=d->>'carrier',tracking_number=d->>'tracking_number',
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
