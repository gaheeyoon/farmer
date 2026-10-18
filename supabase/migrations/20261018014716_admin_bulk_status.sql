-- One transaction for a page of selected orders. Reuse the existing, audited
-- transition logic and per-order request UUIDs for safe retries.
create or replace function public.farmer_admin_bulk_status(p_orders jsonb, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item record;
  result jsonb;
  results jsonb := '[]'::jsonb;
  item_count integer;
begin
  perform farmer_private.require_admin();
  if p_status is null or p_status not in ('confirmed', 'shipped', 'delivered') then
    raise exception '일괄 변경할 수 없는 주문 상태입니다.';
  end if;
  if p_orders is null or jsonb_typeof(p_orders) <> 'array' then
    raise exception '변경할 주문을 선택해 주세요.';
  end if;
  item_count := jsonb_array_length(p_orders);
  if item_count < 1 or item_count > 50 then
    raise exception '한 번에 1~50건의 주문을 변경할 수 있습니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_orders) as a(v)
    where jsonb_typeof(v) <> 'object'
       or coalesce(jsonb_typeof(v->'order_id'), '') <> 'string'
       or coalesce(jsonb_typeof(v->'request_id'), '') <> 'string'
       or coalesce(jsonb_typeof(v->'expected_version'), '') <> 'number'
       or (v->>'expected_version') !~ '^[1-9][0-9]*$'
       or (v ? 'carrier' and jsonb_typeof(v->'carrier') <> 'string')
       or (v ? 'tracking_number' and jsonb_typeof(v->'tracking_number') <> 'string')
  ) then
    raise exception '주문 변경 정보가 올바르지 않습니다.';
  end if;
  if (select count(distinct x.order_id) from jsonb_to_recordset(p_orders) as x(order_id uuid)) <> item_count
    or (select count(distinct x.request_id) from jsonb_to_recordset(p_orders) as x(request_id uuid)) <> item_count then
    raise exception '중복된 주문 또는 처리 요청이 있습니다.';
  end if;
  -- Acquire every order lock before the inventory lock, in a stable order.
  perform o.id from public.farmer_orders o
    join jsonb_to_recordset(p_orders) as x(order_id uuid) on x.order_id = o.id
    order by o.id for update of o;
  for item in select * from jsonb_to_recordset(p_orders)
    as x(order_id uuid, expected_version bigint, request_id uuid, carrier text, tracking_number text)
    order by order_id
  loop
    result := public.farmer_admin_change_status(
      item.order_id, p_status, item.expected_version, item.request_id,
      coalesce(item.carrier, ''), coalesce(item.tracking_number, '')
    );
    results := results || jsonb_build_array(result || jsonb_build_object('id', item.order_id));
  end loop;
  return jsonb_build_object('processed_count', item_count, 'orders', results);
end;
$$;

revoke all on function public.farmer_admin_bulk_status(jsonb,text) from public, anon;
grant execute on function public.farmer_admin_bulk_status(jsonb,text) to authenticated;
