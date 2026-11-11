-- Return the declared sender only through the existing admin-only order export.
CREATE OR REPLACE FUNCTION public.farmer_admin_export_orders(p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;count_all integer;
begin
 perform farmer_private.require_admin();
 if length(coalesce(p_search,''))>100 or coalesce(p_kind,'') not in ('','sale','gift') or coalesce(p_status,'') not in ('','pending','confirmed','confirmed_waiting_address','confirmed_ready','shipped','delivered','cancelled','deleted') then raise exception '조회 조건을 확인해 주세요.';end if;
 -- One snapshot, bounded memory. Never silently truncate an export.
 select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('gift_sender_name',g.sender_name) order by t.created_at desc,t.id),'[]'::jsonb),count(*) into rows,count_all from
 (select * from farmer_private.filtered_admin_orders(p_status,p_search,p_kind) order by created_at desc,id limit 10001)t
 left join farmer_private.gift_links g on g.order_id=t.id;
 if count_all>10000 then raise exception '한 번에 10,000건까지 내려받을 수 있습니다. 검색 조건을 좁혀 주세요.';end if;
 return jsonb_build_object('orders',rows,'total',count_all,'exported_at',now());
end $function$;
