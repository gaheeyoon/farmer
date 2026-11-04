-- Add a 3kg shipping product; existing products, orders, receipts and inventory stay unchanged.
insert into public.farmer_products(id,name,weight_grams,price,active)
values('hopungmi-3kg','호풍미 3kg',3000,16000,true)
on conflict(id) do update set name=excluded.name,weight_grams=excluded.weight_grams,price=excluded.price,active=excluded.active;
create or replace function public.farmer_admin_summary() returns jsonb
language plpgsql security definer set search_path='' as $$
declare data jsonb; stage record;
begin
 perform farmer_private.require_admin();
 select jsonb_build_object('available_kg',available_grams/1000.0,
  'inventory_version',version,'inventory_updated_at',updated_at) into data
 from public.farmer_inventory where id;
 for stage in
  select stages.status,count(o.id) as order_count,
   coalesce(sum(o.weight_grams),0)/1000.0 as kg,
   coalesce(sum(o.quantity),0) as boxes,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*2000),0) as boxes2,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*3000),0) as boxes3,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*5000),0) as boxes5,
   coalesce(sum(o.total),0) as amount
  from (values ('pending'),('confirmed'),('shipped'),('shipped_unpaid'),('delivered')) stages(status)
  left join public.farmer_orders o on o.status=stages.status and o.deleted_at is null
  group by stages.status
 loop
  data:=data||jsonb_build_object(stage.status,stage.order_count,
   stage.status||'_kg',stage.kg,stage.status||'_boxes',stage.boxes,
   stage.status||'_2kg_boxes',stage.boxes2,stage.status||'_3kg_boxes',stage.boxes3,stage.status||'_5kg_boxes',stage.boxes5);
  if stage.status='shipped_unpaid' then
   data:=data||jsonb_build_object('shipped_unpaid_amount',stage.amount);
  end if;
 end loop;
 -- Combined confirmed counters remain compatible; the admin uses disjoint stages.
 for stage in
  select stages.status,count(o.id) as order_count,coalesce(sum(o.weight_grams),0)/1000.0 as kg,
   coalesce(sum(o.quantity),0) as boxes,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*2000),0) as boxes2,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*3000),0) as boxes3,
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*5000),0) as boxes5
  from (values ('confirmed_waiting_address'),('confirmed_ready')) stages(status)
  left join farmer_private.admin_order_rows o on o.status='confirmed' and o.deleted_at is null
   and (case when stages.status='confirmed_waiting_address' then o.awaiting_address else not o.awaiting_address end)
  group by stages.status
 loop
  data:=data||jsonb_build_object(stage.status,stage.order_count,stage.status||'_kg',stage.kg,
   stage.status||'_boxes',stage.boxes,stage.status||'_2kg_boxes',stage.boxes2,stage.status||'_3kg_boxes',stage.boxes3,stage.status||'_5kg_boxes',stage.boxes5);
 end loop;
 return data;
end $$;

create or replace function public.farmer_admin_free_gift_summary(p_year integer) returns jsonb
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
   case when o.order_kind='gift' then coalesce(o.gift_sponsor,case when g.sender_name in ('윤가희','홍세환','윤가희&홍세환') then g.sender_name end,'미지정')
    when o.discount_code='고구맙습니다홍세환선물용' then '홍세환' else '윤가희' end as sponsor
  from public.farmer_orders o left join farmer_private.gift_links g on g.order_id=o.id
  where o.deleted_at is null and o.status in ('pending','confirmed','shipped','delivered') and o.created_at>=start_at and o.created_at<end_at
   and ((o.order_kind='gift' and o.total=0) or (o.order_kind='sale' and o.discount_code in ('고구맙습니다홍세환선물용','고구맙습니다윤가희선물용') and o.unit_price>0 and o.discount_amount>=o.unit_price))
 ),gifts as (select * from units where free_boxes>0),
 people as (
  select n.sponsor,coalesce(sum(g.free_boxes),0) as boxes,coalesce(sum(g.free_boxes*g.unit_grams),0)/1000.0 as kg,
   coalesce(sum(g.free_boxes) filter(where g.product_id in ('hopungmi-5kg','hopungmi-5kg-pickup')),0) as qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-5kg-pickup'),0) as pickup_qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-5kg'),0) as shipping_qty5,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-3kg'),0) as qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-2kg'),0) as qty2,
   coalesce(sum(g.free_boxes) filter(where g.status='pending'),0) as pending_boxes
  from (values('윤가희',1),('홍세환',2),('윤가희&홍세환',3),('미지정',4))n(sponsor,position) left join gifts g on g.sponsor=n.sponsor group by n.sponsor,n.position order by n.position
 )
 select jsonb_build_object('year',p_year,'totals',jsonb_build_object(
  'boxes',coalesce(sum(free_boxes),0),'kg',coalesce(sum(free_boxes*unit_grams),0)/1000.0,
  'qty5',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-5kg','hopungmi-5kg-pickup')),0),
  'pickup_qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg-pickup'),0),
  'shipping_qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg'),0),
  'qty3',coalesce(sum(free_boxes) filter(where product_id='hopungmi-3kg'),0),
  'qty2',coalesce(sum(free_boxes) filter(where product_id='hopungmi-2kg'),0),
  'pending_boxes',coalesce(sum(free_boxes) filter(where status='pending'),0),
  'reserved_boxes',coalesce(sum(free_boxes) filter(where status<>'pending'),0)),
  'people',(select jsonb_agg(to_jsonb(p)) from people p)) into result from gifts;
 return result;
end $$;

create or replace function public.farmer_admin_hanjin_preview(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item jsonb;result jsonb:='[]';candidates jsonb;reason text;phone_value text;name_value text;track text;
begin
 perform farmer_private.require_admin();
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 500 or length(p_rows::text)>1000000 then raise exception '1~500상자의 한진 배송 내역을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$')
 or (select count(distinct x->>'row') from jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) then raise exception '엑셀 행 정보를 확인해 주세요.';end if;
 for item in select value from jsonb_array_elements(p_rows) loop
  track:=coalesce(item->>'tracking','');phone_value:=regexp_replace(coalesce(item->>'phone',''),'[[:space:]()-]','','g');name_value:=farmer_private.hanjin_name(item->>'name');reason:='';candidates:='[]';
  if track !~ '^[0-9]{12}$' then reason:='한진 운송장번호 12자리를 확인해 주세요.';
  elsif (select count(*) from jsonb_array_elements(p_rows) x where x->>'tracking'=track)>1 then reason:='파일 안에 같은 송장번호가 중복되어 있습니다.';
  elsif coalesce(item->>'quantity','')<>'1' then reason:='송장 한 개당 수량은 1상자여야 합니다.';
  elsif coalesce(item->>'weight_grams','') not in ('2000','3000','5000') then reason:='품목명의 2kg·3kg·5kg 중량을 확인해 주세요.';
  elsif length(name_value)>100 or length(name_value)=0 or length(regexp_replace(phone_value,'[^0-9]','','g'))<6 or length(phone_value)>20 or phone_value !~ '^[0-9*]+$'
   or coalesce(item->>'postal','') !~ '^[0-9]{5}$' or length(coalesce(item->>'address','')) not between 5 and 250 then reason:='받는 분 이름·연락처·우편번호·주소를 확인해 주세요.';
  elsif coalesce(item->>'order_number','')<>'' and item->>'order_number' !~ '^GF-[0-9]{8}$' then reason:='주문번호 형식을 확인해 주세요.';
  else
   select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number','GF-'||lpad(o.order_no::text,8,'0'),'recipient_name',coalesce(nullif(o.recipient_name,''),o.customer_name),'customer_name',o.customer_name,'quantity',o.quantity,'version',o.version,'status',o.status,'existing',track=any(o.tracking_numbers) or track=o.tracking_number,'carrier',o.carrier) order by o.created_at desc,o.id),'[]') into candidates
   from public.farmer_orders o
   where o.deleted_at is null and o.status<>'cancelled' and o.product_id<>'hopungmi-5kg-pickup'
    and not exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null)
    and (coalesce(item->>'order_number','')='' or 'GF-'||lpad(o.order_no::text,8,'0')=item->>'order_number')
    and o.weight_grams=o.quantity::bigint*(item->>'weight_grams')::integer
    and o.postal_code=item->>'postal'
    and farmer_private.hanjin_address(item->>'address') in (farmer_private.hanjin_address(o.address),farmer_private.hanjin_address(o.address||' '||o.address_detail))
    and farmer_private.hanjin_mask(farmer_private.hanjin_name(coalesce(nullif(o.recipient_name,''),o.customer_name)),name_value)
    and farmer_private.hanjin_mask(regexp_replace(coalesce(nullif(o.recipient_phone,''),o.phone),'[[:space:]()-]','','g'),phone_value)
    and not exists(select 1 from public.farmer_orders other where other.id<>o.id and (track=any(other.tracking_numbers) or track=other.tracking_number));
   if jsonb_array_length(candidates)=0 then reason:='일치하는 주문이 없거나 다른 주문에 등록된 송장입니다.';end if;
  end if;
  result:=result||jsonb_build_array(jsonb_build_object('row',(item->>'row')::integer,'tracking',track,'name',item->>'name','weight_grams',item->>'weight_grams','candidates',candidates,'reason',reason));
 end loop;
 return jsonb_build_object('rows',result,'count',jsonb_array_length(p_rows));
end $$;
