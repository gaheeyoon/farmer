-- Separate registered pickup gifts from shipping gifts without altering orders or stock.
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
   case when o.order_kind='gift' then coalesce(o.gift_sponsor,case when g.sender_name in ('윤가희','홍세환') then g.sender_name end,'미지정')
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
   coalesce(sum(g.free_boxes) filter(where g.product_id='hopungmi-2kg'),0) as qty2,
   coalesce(sum(g.free_boxes) filter(where g.status='pending'),0) as pending_boxes
  from (values('윤가희',1),('홍세환',2),('미지정',3))n(sponsor,position) left join gifts g on g.sponsor=n.sponsor group by n.sponsor,n.position order by n.position
 )
 select jsonb_build_object('year',p_year,'totals',jsonb_build_object(
  'boxes',coalesce(sum(free_boxes),0),'kg',coalesce(sum(free_boxes*unit_grams),0)/1000.0,
  'qty5',coalesce(sum(free_boxes) filter(where product_id in ('hopungmi-5kg','hopungmi-5kg-pickup')),0),
  'pickup_qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg-pickup'),0),
  'shipping_qty5',coalesce(sum(free_boxes) filter(where product_id='hopungmi-5kg'),0),
  'qty2',coalesce(sum(free_boxes) filter(where product_id='hopungmi-2kg'),0),
  'pending_boxes',coalesce(sum(free_boxes) filter(where status='pending'),0),
  'reserved_boxes',coalesce(sum(free_boxes) filter(where status<>'pending'),0)),
  'people',(select jsonb_agg(to_jsonb(p)) from people p)) into result from gifts;
 return result;
end $$;
