-- Keep the 2kg product visible as sold out when sales are paused.
-- Checkout still requires active=true; existing orders and gift claims are unchanged.
create or replace function public.farmer_catalog() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'weight_grams', p.weight_grams,
        'price', p.price,
        'fulfillment_method', case when p.id = 'hopungmi-5kg-pickup' then 'pickup' else 'shipping' end,
        'available', p.active and i.available_grams >= p.weight_grams
      ) order by p.weight_grams, case when p.id = 'hopungmi-5kg-pickup' then 1 else 0 end, p.id), '[]'::jsonb)
      from public.farmer_products p cross join public.farmer_inventory i
      where p.active or p.id = 'hopungmi-2kg'
    ),
    'shipping_fee', 0,
    'pickup_location', jsonb_build_object('address', '원북면 원이로 804-59', 'name', '홍세환 소셜라운지')
  );
$$;
