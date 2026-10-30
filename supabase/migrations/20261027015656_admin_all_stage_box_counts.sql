-- Count actual boxes (quantity), independently of order count, for every stage.
-- Saved order weight identifies size, including inactive SKUs and free pickup gifts.
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
   coalesce(sum(o.quantity) filter(where o.weight_grams=o.quantity::bigint*5000),0) as boxes5,
   coalesce(sum(o.total),0) as amount
  from (values ('pending'),('confirmed'),('shipped'),('shipped_unpaid'),('delivered')) stages(status)
  left join public.farmer_orders o on o.status=stages.status and o.deleted_at is null
  group by stages.status
 loop
  data:=data||jsonb_build_object(stage.status,stage.order_count,
   stage.status||'_kg',stage.kg,stage.status||'_boxes',stage.boxes,
   stage.status||'_2kg_boxes',stage.boxes2,stage.status||'_5kg_boxes',stage.boxes5);
  if stage.status='shipped_unpaid' then
   data:=data||jsonb_build_object('shipped_unpaid_amount',stage.amount);
  end if;
 end loop;
 return data;
end $$;
-- Existing authenticated-only EXECUTE grant and require_admin remain unchanged.
