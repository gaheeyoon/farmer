-- Shared administrator-only cost assumptions. Estimates never create ledger entries.
create table farmer_private.fulfillment_cost_settings (
 singleton boolean primary key default true check(singleton),
 shipping integer not null default 4000 check(shipping between 0 and 100000000),
 packing integer not null default 1500 check(packing between 0 and 100000000),
 version bigint not null default 1,
 updated_at timestamptz not null default now(), updated_by uuid
);
insert into farmer_private.fulfillment_cost_settings(singleton) values(true);
alter table farmer_private.fulfillment_cost_settings enable row level security;
revoke all on farmer_private.fulfillment_cost_settings from public,anon,authenticated;

create function public.farmer_admin_fulfillment_costs(p_year integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; starts timestamptz; ends timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 then raise exception '연도를 확인해 주세요.'; end if;
 starts:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');
 ends:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with eligible as (
  select quantity, product_id from public.farmer_orders
  where deleted_at is null and status in ('confirmed','shipped','delivered')
   and coalesce(confirmed_at,created_at)>=starts and coalesce(confirmed_at,created_at)<ends
 ), costs as (
  select coalesce(sum(amount) filter(where category='배송비'),0) as recorded_shipping,
   coalesce(sum(amount) filter(where category='포장비'),0) as recorded_packing
  from farmer_private.finance_entries where deleted_at is null and direction='expense'
   and occurred_on>=make_date(p_year,1,1) and occurred_on<make_date(p_year+1,1,1)
 )
 select jsonb_build_object('year',p_year,
  'settings',(select jsonb_build_object('shipping',shipping,'packing',packing,'version',version) from farmer_private.fulfillment_cost_settings where singleton),
  'shipping_boxes',coalesce((select sum(quantity) from eligible where product_id<>'hopungmi-5kg-pickup'),0),
  'pickup_boxes',coalesce((select sum(quantity) from eligible where product_id='hopungmi-5kg-pickup'),0),
  'recorded_shipping',costs.recorded_shipping,'recorded_packing',costs.recorded_packing)
 into result from costs;
 return result;
end $$;

create function public.farmer_admin_save_fulfillment_costs(p_shipping integer,p_packing integer,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare setting farmer_private.fulfillment_cost_settings;
begin
 perform farmer_private.require_admin();
 if p_shipping is null or p_packing is null or p_shipping not between 0 and 100000000
  or p_packing not between 0 and 100000000 or p_expected_version is null then raise exception '택배비와 상자비를 0 이상의 정수로 입력해 주세요.'; end if;
 select * into setting from farmer_private.fulfillment_cost_settings where singleton for update;
 if setting.version<>p_expected_version then
  -- A retry of the same settings is safe even when the first response was lost.
  if setting.shipping=p_shipping and setting.packing=p_packing then
   return jsonb_build_object('shipping',setting.shipping,'packing',setting.packing,'version',setting.version);
  end if;
  raise exception '다른 화면에서 기본 비용이 변경되었습니다. 새로고침해 주세요.';
 end if;
 update farmer_private.fulfillment_cost_settings set shipping=p_shipping,packing=p_packing,
  version=version+1,updated_at=now(),updated_by=auth.uid() where singleton returning * into setting;
 return jsonb_build_object('shipping',setting.shipping,'packing',setting.packing,'version',setting.version);
end $$;
revoke all on function public.farmer_admin_fulfillment_costs(integer),public.farmer_admin_save_fulfillment_costs(integer,integer,bigint) from public,anon,authenticated;
grant execute on function public.farmer_admin_fulfillment_costs(integer),public.farmer_admin_save_fulfillment_costs(integer,integer,bigint) to authenticated;
