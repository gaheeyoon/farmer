-- Admin-only import. Unique product-order IDs and request receipts prevent duplicate stock deductions.
create table farmer_private.naver_import_requests (
 request_id uuid primary key, actor uuid not null, fingerprint text not null,
 receipt jsonb not null, created_at timestamptz not null default now()
);
alter table farmer_private.naver_import_requests enable row level security;
revoke all on farmer_private.naver_import_requests from public,anon,authenticated;

create function farmer_private.naver_line(d jsonb) returns jsonb
language plpgsql stable set search_path='' as $$
declare p public.farmer_products;qty integer;unit integer;goods integer;shipping integer;ordered timestamptz;paid timestamptz;method text;
begin
 if jsonb_typeof(d)<>'object' or coalesce(d->>'external_id','') !~ '^[0-9]{10,30}$' or coalesce(d->>'external_order','') !~ '^[0-9]{10,30}$' then raise exception '네이버 상품주문번호와 주문번호를 확인해 주세요.';end if;
 if coalesce(d->>'quantity','') !~ '^[1-9][0-9]?$' then raise exception '수량은 1~99상자여야 합니다.';end if;
 if coalesce(d->>'unit_price','') !~ '^[0-9]{1,8}$' or coalesce(d->>'goods_total','') !~ '^[0-9]{1,9}$' or coalesce(d->>'shipping_fee','') !~ '^[0-9]{1,7}$' then raise exception '상품 금액과 배송비를 확인해 주세요.';end if;
 qty:=(d->>'quantity')::integer;unit:=(d->>'unit_price')::integer;goods:=(d->>'goods_total')::integer;shipping:=(d->>'shipping_fee')::integer;
 if unit::bigint*qty>999999999 or goods>unit::bigint*qty then raise exception '수량·상품가격·최종 상품별 총 주문금액이 맞지 않습니다.';end if;
 select * into p from public.farmer_products where id=d->>'product_id' and id in ('hopungmi-2kg','hopungmi-3kg','hopungmi-5kg');
 if not found then raise exception '상품명 또는 옵션에서 2kg·3kg·5kg 한 가지 중량을 확인할 수 없습니다.';end if;
 if coalesce(d->>'source_status','') not in ('발송대기','결제완료','신규주문') or coalesce(d->>'claim','') not in ('','N','없음','아니오') then raise exception '결제 완료된 미발송 주문만 등록할 수 있습니다. 취소·반품·교환·발송 여부를 확인해 주세요.';end if;
 if coalesce(d->>'paid_at','') !~ '^\d{4}-\d{2}-\d{2}T' or coalesce(d->>'ordered_at','') !~ '^\d{4}-\d{2}-\d{2}T' then raise exception '결제일과 주문일시를 확인해 주세요.';end if;
 ordered:=(d->>'ordered_at')::timestamptz;paid:=(d->>'paid_at')::timestamptz;
 if paid<ordered or paid>now()+interval '1 day' then raise exception '주문일시와 결제일을 확인해 주세요.';end if;
 if length(btrim(coalesce(d->>'customer_name',''))) not between 1 and 40 or length(btrim(coalesce(d->>'recipient_name',''))) not between 1 and 100
 or coalesce(d->>'phone','') !~ '^0[0-9]{8,11}$' or coalesce(d->>'recipient_phone','') !~ '^0[0-9]{8,11}$' then raise exception '주문자·받는 분 성함과 연락처를 확인해 주세요. 안심번호는 그대로 사용합니다.';end if;
 if coalesce(d->>'postal_code','') !~ '^[0-9]{5}$' or length(coalesce(d->>'address','')) not between 5 and 200 or length(coalesce(d->>'address_detail',''))>120 or length(coalesce(d->>'memo',''))>300 then raise exception '우편번호·주소·배송 메모를 확인해 주세요.';end if;
 if length(coalesce(d->>'shipping_group',''))>80 or length(coalesce(d->>'source_product',''))>500 or length(coalesce(d->>'source_option',''))>500 then raise exception '상품과 배송비 묶음 정보를 확인해 주세요.';end if;
 method:=coalesce(d->>'method','');if method not in ('택배,등기,소포','택배','방문수령') then raise exception '택배 또는 방문수령 주문만 등록할 수 있습니다.';end if;
 if method='방문수령' and shipping<>0 then raise exception '방문수령 주문의 배송비를 확인해 주세요.';end if;
 return d||jsonb_build_object('product_name','[네이버] '||p.name,'weight_grams',p.weight_grams::bigint*qty,'subtotal',unit*qty,'discount_amount',unit*qty-goods,'pickup_requested',method='방문수령','shipping_key',(d->>'external_order')||':'||coalesce(nullif(d->>'shipping_group',''),d->>'external_id'));
end $$;
revoke all on function farmer_private.naver_line(jsonb) from public,anon,authenticated;

create function public.farmer_admin_naver_preview(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d jsonb;line jsonb;result jsonb:='[]';existing record;reason text;kind text;
begin
 perform farmer_private.require_admin();
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 500 or length(p_rows::text)>2000000 then raise exception '1~500건의 네이버 주문을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_rows)x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$') or (select count(distinct x->>'row') from jsonb_array_elements(p_rows)x)<>jsonb_array_length(p_rows) then raise exception '엑셀 행 정보를 확인해 주세요.';end if;
 for d in select value from jsonb_array_elements(p_rows) loop
  reason:='';kind:='ready';line:=d;
  select o.id,'GF-'||lpad(o.order_no::text,8,'0') order_number into existing from farmer_private.external_order_imports e join public.farmer_orders o on o.id=e.order_id where e.channel='naver' and e.external_product_order_id=d->>'external_id';
  if found then kind:='existing';reason:='이미 등록됨 · '||existing.order_number;
  elsif (select count(*) from jsonb_array_elements(p_rows)x where x->>'external_id'=d->>'external_id')>1 then kind:='invalid';reason:='파일 안에 같은 상품주문번호가 중복되어 있습니다.';
  else
   begin
    line:=farmer_private.naver_line(d);
    if (line->>'shipping_fee')::integer>0 and exists(select 1 from jsonb_array_elements(p_rows)x where x->>'external_order'=d->>'external_order' and coalesce(x->>'shipping_group','')=coalesce(d->>'shipping_group','') and coalesce(d->>'shipping_group','')<>'' and x->>'shipping_fee'<>d->>'shipping_fee') then raise exception '같은 배송비 묶음의 배송비 금액이 서로 다릅니다.';end if;
   exception when others then kind:='invalid';reason:=sqlerrm;end;
  end if;
  result:=result||jsonb_build_array(jsonb_build_object('row',(d->>'row')::integer,'external_id',d->>'external_id','kind',kind,'reason',reason,'order_number',case when kind='existing' then existing.order_number else null end,'product_name',line->>'product_name','weight_grams',case when kind='ready' then (line->>'weight_grams')::bigint else 0 end));
 end loop;
 return jsonb_build_object('rows',result,'available_kg',(select available_grams/1000.0 from public.farmer_inventory where id));
end $$;

create function public.farmer_admin_import_naver(p_request_id uuid,p_rows jsonb,p_selected jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old farmer_private.naver_import_requests;fp text;preview jsonb;d jsonb;line jsonb;item jsonb;o public.farmer_orders;
 receipt jsonb;receipts jsonb:='[]';added integer:=0;skipped integer:=0;weight bigint:=0;shipping integer;charged boolean;
begin
 perform farmer_private.require_admin();
 if p_request_id is null then raise exception '요청 번호를 확인해 주세요.';end if;
 fp:=md5(jsonb_build_array(auth.uid(),p_rows,p_selected)::text);
 perform pg_advisory_xact_lock(hashtextextended('naver-order-import',0));
 select * into old from farmer_private.naver_import_requests where request_id=p_request_id;
 if found then if old.actor<>auth.uid() or old.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.';end if;return old.receipt;end if;
 preview:=public.farmer_admin_naver_preview(p_rows);
 if p_selected is null or jsonb_typeof(p_selected)<>'array' or jsonb_array_length(p_selected) not between 1 and 500 or exists(select 1 from jsonb_array_elements(p_selected)x where jsonb_typeof(x)<>'number' or x::text !~ '^[1-9][0-9]{0,5}$') or (select count(distinct x::text) from jsonb_array_elements(p_selected)x)<>jsonb_array_length(p_selected) then raise exception '등록할 행을 선택해 주세요.';end if;
 for item in select value from jsonb_array_elements(p_selected) order by (value::text)::integer loop
  select value into line from jsonb_array_elements(preview->'rows') where (value->>'row')::integer=(item::text)::integer;
  if not found then raise exception '선택한 행을 찾을 수 없습니다.';end if;
  if line->>'kind'='existing' then skipped:=skipped+1;continue;end if;
  if line->>'kind'<>'ready' then raise exception '%행: %',line->>'row',line->>'reason';end if;
  select value into d from jsonb_array_elements(p_rows) where value->>'row'=line->>'row';line:=farmer_private.naver_line(d);
  shipping:=(line->>'shipping_fee')::integer;
  select exists(select 1 from farmer_private.external_order_imports where channel='naver' and source_payment->>'shipping_key'=line->>'shipping_key' and (source_payment->>'shipping_charged')::boolean) into charged;
  if charged then shipping:=0;end if;
  insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,discount_code,discount_amount,shipping_fee,total,customer_name,phone,recipient_name,recipient_phone,postal_code,address,address_detail,memo,order_kind,created_by,pickup_requested,created_at)
  values(gen_random_uuid(),md5(d::text),line->>'product_id',line->>'product_name',(line->>'quantity')::integer,(line->>'weight_grams')::bigint,(line->>'unit_price')::integer,(line->>'subtotal')::integer,null,(line->>'discount_amount')::integer,shipping,(line->>'goods_total')::integer+shipping,line->>'customer_name',line->>'phone',line->>'recipient_name',line->>'recipient_phone',line->>'postal_code',line->>'address',coalesce(line->>'address_detail',''),coalesce(line->>'memo',''),'sale',auth.uid(),(line->>'pickup_requested')::boolean,(line->>'ordered_at')::timestamptz) returning * into o;
  insert into farmer_private.external_order_imports(order_id,channel,external_order_id,external_product_order_id,source_ordered_at,source_paid_at,source_payment,imported_by)
  values(o.id,'naver',line->>'external_order',line->>'external_id',(line->>'ordered_at')::timestamptz,(line->>'paid_at')::timestamptz,jsonb_build_object('gross_total',o.total,'shipping_fee',shipping,'shipping_key',line->>'shipping_key','shipping_charged',shipping>0,'fee_amount',line->'fee_amount','expected_settlement',line->'settlement','source_product',line->'source_product','source_option',line->'source_option'),auth.uid());
  perform public.farmer_admin_change_status(o.id,'confirmed',o.version,gen_random_uuid());
  added:=added+1;weight:=weight+o.weight_grams;
  receipts:=receipts||jsonb_build_array(jsonb_build_object('order_number','GF-'||lpad(o.order_no::text,8,'0'),'external_id',line->>'external_id'));
 end loop;
 receipt:=jsonb_build_object('saved',true,'added',added,'skipped',skipped,'weight_kg',weight/1000.0,'orders',receipts,'available_kg',(select available_grams/1000.0 from public.farmer_inventory where id));
 insert into farmer_private.naver_import_requests values(p_request_id,auth.uid(),fp,receipt,now());
 return receipt;
end $$;
revoke all on function public.farmer_admin_naver_preview(jsonb),public.farmer_admin_import_naver(uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.farmer_admin_naver_preview(jsonb),public.farmer_admin_import_naver(uuid,jsonb,jsonb) to authenticated;
