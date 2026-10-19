-- Convenience lookup returns masked gift receipts, never bearer links or addresses.
-- Share links remain available only to a browser holding the original purchase receipt.
create function public.farmer_lookup_gifts(p_customer_name text,p_phone text,p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
declare name_value text; phone_value text; attempts_value integer; window_value timestamptz;
 rows jsonb; count_value bigint;
begin
 if length(coalesce(p_customer_name,''))>40 or length(coalesce(p_phone,''))>40
    or p_offset is null or p_offset<0 or p_offset>100000 then return jsonb_build_object('found',false); end if;
 name_value:=btrim(coalesce(p_customer_name,''));
 phone_value:=regexp_replace(coalesce(p_phone,''),'[[:space:]()-]','','g');
 if length(name_value)=0 or phone_value !~ '^0[0-9]{8,10}$' then return jsonb_build_object('found',false); end if;
 -- Share the existing phone limit across order and gift receipt lookups.
 delete from farmer_private.order_lookup_limits where window_started<now()-interval '1 day';
 insert into farmer_private.order_lookup_limits(bucket) values('phone:'||md5(phone_value))
 on conflict(bucket) do update set
  attempts=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then 1 else least(order_lookup_limits.attempts+1,100000) end,
  window_started=case when order_lookup_limits.window_started<=now()-interval '15 minutes' then now() else order_lookup_limits.window_started end
 returning attempts,window_started into attempts_value,window_value;
 if attempts_value>20 then return jsonb_build_object('found',false,'retry_after',greatest(1,ceil(extract(epoch from window_value+interval '15 minutes'-now()))::integer)); end if;
 select count(*) into count_value from public.farmer_orders o join farmer_private.gift_links g on g.order_id=o.id
 where o.customer_name=name_value and o.phone=phone_value and o.order_kind='sale';
 if count_value=0 then return jsonb_build_object('found',false); end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'order_number','GF-'||lpad(x.order_no::text,8,'0'),'product_name',x.product_name,'quantity',x.quantity,
  'subtotal',x.subtotal,'discount_amount',x.discount_amount,'total',x.total,'status',x.status,
  'state',case when x.status='cancelled' then 'cancelled' when x.claimed_at is not null then 'claimed' when x.status='pending' then 'pending' when x.expires_at<=now() then 'expired' else 'ready' end,
  'recipient_label',left(x.recipient_label,1)||repeat('*',least(3,greatest(1,length(x.recipient_label)-1))),
  'created_at',x.created_at,'expires_at',x.expires_at,'claimed_at',x.claimed_at,'delivered_at',x.delivered_at
 ) order by x.created_at desc,x.order_no desc),'[]'::jsonb) into rows
 from (select o.*,g.recipient_label,g.expires_at,g.claimed_at from public.farmer_orders o join farmer_private.gift_links g on g.order_id=o.id
  where o.customer_name=name_value and o.phone=phone_value and o.order_kind='sale'
  order by o.created_at desc,o.order_no desc limit 20 offset p_offset) x;
 return jsonb_build_object('found',true,'gifts',rows,'total_count',count_value,'next_offset',case when p_offset+20<count_value then p_offset+20 else null end);
end $$;
revoke all on function public.farmer_lookup_gifts(text,text,integer) from public,anon,authenticated;
grant execute on function public.farmer_lookup_gifts(text,text,integer) to anon,authenticated;
