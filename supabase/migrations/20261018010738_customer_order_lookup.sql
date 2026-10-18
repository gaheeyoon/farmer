-- Name and phone are a convenience lookup, not verified identity. Return only masked receipts.
create table farmer_private.order_lookup_limits (
  bucket text primary key,
  window_started timestamptz not null default now(),
  attempts integer not null default 1
);
alter table farmer_private.order_lookup_limits enable row level security;
revoke all on farmer_private.order_lookup_limits from public,anon,authenticated;
create index order_lookup_limits_window on farmer_private.order_lookup_limits(window_started);
create index farmer_orders_customer_lookup on public.farmer_orders(phone,customer_name,created_at desc,order_no desc);

create function public.farmer_lookup_orders(p_customer_name text,p_phone text,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  name_value text; phone_value text; attempts_value integer; window_value timestamptz;
  rows jsonb; count_value bigint; next_value integer;
begin
  if length(coalesce(p_customer_name,''))>40 or length(coalesce(p_phone,''))>40
     or p_offset is null or p_offset<0 or p_offset>100000 then
    return jsonb_build_object('found',false);
  end if;
  name_value:=btrim(coalesce(p_customer_name,''));
  phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
  if length(name_value)=0 or phone_value !~ '^(0[0-9]{8,10}|\+82[0-9]{8,10})$' then
    return jsonb_build_object('found',false);
  end if;
  -- Return failures, rather than raising, so rate-limit counters are committed.
  delete from farmer_private.order_lookup_limits where window_started<now()-interval '1 day';
  insert into farmer_private.order_lookup_limits(bucket) values('phone:'||md5(phone_value))
  on conflict(bucket) do update set
    attempts=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then 1 else least(order_lookup_limits.attempts+1,100000) end,
    window_started=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then now() else order_lookup_limits.window_started end
  returning attempts,window_started into attempts_value,window_value;
  if attempts_value>20 then
    return jsonb_build_object('found',false,'retry_after',greatest(1,ceil(extract(epoch from window_value+interval '15 minutes'-now()))::integer));
  end if;
  select count(*) into count_value from public.farmer_orders where customer_name=name_value and phone=phone_value;
  if count_value=0 then return jsonb_build_object('found',false); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_number','GF-'||lpad(o.order_no::text,8,'0'),
    'product_name',o.product_name,'quantity',o.quantity,'subtotal',o.subtotal,
    'discount_amount',o.discount_amount,'shipping_fee',o.shipping_fee,'total',o.total,'status',o.status,
    'recipient_name',left(coalesce(nullif(o.recipient_name,''),o.customer_name),1)||repeat('*',least(3,greatest(1,length(coalesce(nullif(o.recipient_name,''),o.customer_name))-1))),
    'created_at',o.created_at,'delivered_at',o.delivered_at
  ) order by o.created_at desc,o.order_no desc),'[]'::jsonb) into rows
  from (select * from public.farmer_orders where customer_name=name_value and phone=phone_value
        order by created_at desc,order_no desc limit 20 offset p_offset) o;
  next_value:=case when p_offset+20<count_value then p_offset+20 else null end;
  return jsonb_build_object('found',true,'orders',rows,'total_count',count_value,'next_offset',next_value);
end $$;
revoke all on function public.farmer_lookup_orders(text,text,integer) from public,anon,authenticated;
grant execute on function public.farmer_lookup_orders(text,text,integer) to anon,authenticated;
