-- Count boxes across all confirmed orders, including gifts and pickup.
-- Stored order weights preserve the size even if the catalog changes later.
create or replace function public.farmer_admin_summary() returns jsonb
language plpgsql security definer set search_path='' as $$
declare data jsonb;
begin
 perform farmer_private.require_admin();
 select jsonb_build_object(
  'available_kg',i.available_grams/1000.0,'inventory_version',i.version,'inventory_updated_at',i.updated_at,
  'pending',a.pending,'pending_kg',a.pending_kg,
  'confirmed',a.confirmed,'confirmed_kg',a.confirmed_kg,
  'confirmed_2kg_boxes',a.confirmed_2kg_boxes,'confirmed_5kg_boxes',a.confirmed_5kg_boxes,
  'shipped',a.shipped,'shipped_kg',a.shipped_kg,
  'delivered',a.delivered,'delivered_kg',a.delivered_kg
 ) into data from public.farmer_inventory i cross join (
  select count(*) filter(where status='pending') as pending,
   coalesce(sum(weight_grams) filter(where status='pending'),0)/1000.0 as pending_kg,
   count(*) filter(where status='confirmed') as confirmed,
   coalesce(sum(weight_grams) filter(where status='confirmed'),0)/1000.0 as confirmed_kg,
   coalesce(sum(quantity) filter(where status='confirmed' and weight_grams=quantity::bigint*2000),0) as confirmed_2kg_boxes,
   coalesce(sum(quantity) filter(where status='confirmed' and weight_grams=quantity::bigint*5000),0) as confirmed_5kg_boxes,
   count(*) filter(where status='shipped') as shipped,
   coalesce(sum(weight_grams) filter(where status='shipped'),0)/1000.0 as shipped_kg,
   count(*) filter(where status='delivered') as delivered,
   coalesce(sum(weight_grams) filter(where status='delivered'),0)/1000.0 as delivered_kg
  from public.farmer_orders where deleted_at is null
 ) a where i.id;
 return data;
end $$;
