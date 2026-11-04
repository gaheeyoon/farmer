-- A pickup counterpart preserves the chosen weight and price through every RPC.
-- Existing orders, prices, stock and receipts are not rewritten.
insert into public.farmer_products(id,name,weight_grams,price,active)
select 'hopungmi-3kg-pickup','호풍미 3kg 방문 수령',weight_grams,price,active
from public.farmer_products where id='hopungmi-3kg'
on conflict(id) do nothing;

create function farmer_private.is_pickup_product(p_id text) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(p_id in ('hopungmi-3kg-pickup','hopungmi-5kg-pickup'),false);
$$;
revoke all on function farmer_private.is_pickup_product(text) from public,anon,authenticated;

-- Extend only pickup predicates in the existing implementations. Keeping their
-- full definitions preserves authorization, validation, retries and inventory locks.
do $$
declare f record; definition text; token text; gap text;
begin
 for f in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname=any(array[
   'farmer_admin_gift_catalog','farmer_quote_gifts','farmer_submit_order','farmer_catalog',
   'farmer_admin_hanjin_preview','farmer_admin_create_gifts','farmer_quote_batch',
   'farmer_lookup_orders','farmer_admin_change_status','farmer_admin_create_gift_link',
   'farmer_buy_gifts','farmer_admin_update_delivery','farmer_admin_fulfillment_costs'])
 loop
  definition:=pg_get_functiondef(f.oid);
  foreach token in array array['o.product_id','p.id','d->>''product_id''','p_product_id','product_id','id'] loop
   foreach gap in array array['',' '] loop
    definition:=replace(definition,token||gap||'<>'||gap||'''hopungmi-5kg-pickup''','(not farmer_private.is_pickup_product('||token||'))');
    definition:=replace(definition,token||gap||'='||gap||'''hopungmi-5kg-pickup''','farmer_private.is_pickup_product('||token||')');
   end loop;
  end loop;
  if f.proname='farmer_admin_gift_catalog' then
   definition:=replace(definition,'''hopungmi-2kg'',''hopungmi-5kg-pickup''','''hopungmi-2kg'',''hopungmi-3kg-pickup'',''hopungmi-5kg-pickup''');
  end if;
  execute definition;
 end loop;
end $$;

-- Keep 5kg-only figures intact and count 3kg shipping/pickup gifts separately.
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.farmer_admin_free_gift_summary(integer)'::regprocedure);
 definition:=replace(definition,'g.product_id=''hopungmi-3kg''','g.product_id in (''hopungmi-3kg'',''hopungmi-3kg-pickup'')');
 definition:=replace(definition,'where product_id=''hopungmi-3kg''','where product_id in (''hopungmi-3kg'',''hopungmi-3kg-pickup'')');
 definition:=replace(definition,' as qty3,',' as qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id=''hopungmi-3kg-pickup''),0) as pickup_qty3,
   coalesce(sum(g.free_boxes) filter(where g.product_id=''hopungmi-3kg''),0) as shipping_qty3,');
 definition:=replace(definition,'''qty2'',coalesce(sum(free_boxes)',
  '''pickup_qty3'',coalesce(sum(free_boxes) filter(where product_id=''hopungmi-3kg-pickup''),0),
  ''shipping_qty3'',coalesce(sum(free_boxes) filter(where product_id=''hopungmi-3kg''),0),
  ''qty2'',coalesce(sum(free_boxes)');
 execute definition;
end $$;
