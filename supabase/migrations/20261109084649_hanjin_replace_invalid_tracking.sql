-- Replace only invalid Hanjin placeholders, after strict identity and version checks.
-- Genuine 12-digit waybills, other couriers, stock and order identities stay protected.
CREATE OR REPLACE FUNCTION public.farmer_admin_hanjin_preview(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item jsonb;result jsonb:='[]';candidates jsonb;reason text;phone_value text;name_value text;track text;
begin
 perform farmer_private.require_admin();
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 500 or length(p_rows::text)>1000000 then raise exception '1~500상자의 한진 배송 내역을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$')
 or (select count(distinct x->>'row') from jsonb_array_elements(p_rows) x)<>jsonb_array_length(p_rows) then raise exception '엑셀 행 정보를 확인해 주세요.';end if;
 for item in select value from jsonb_array_elements(p_rows) loop
  track:=coalesce(item->>'tracking','');phone_value:=regexp_replace(coalesce(item->>'phone',''),'[[:space:]()-]','','g');name_value:=farmer_private.hanjin_name(item->>'name');reason:='';candidates:='[]';
  if track !~ '^[0-9]{12}$' then reason:='한진 운송장번호 12자리를 확인해 주세요.';
  elsif (select count(*) from jsonb_array_elements(p_rows) x where x->>'tracking'=track)>1 then reason:='파일 안에 같은 송장번호가 중복되어 있습니다.';
  elsif coalesce(item->>'quantity','')<>'1' then reason:='송장 한 개당 수량은 1상자여야 합니다.';
  elsif coalesce(item->>'weight_grams','') not in ('2000','3000','5000') then reason:='품목명의 2kg·3kg·5kg 중량을 확인해 주세요.';
  elsif length(name_value)>100 or length(name_value)=0 or length(regexp_replace(phone_value,'[^0-9]','','g'))<6 or length(phone_value)>20 or phone_value !~ '^[0-9*]+$'
   or coalesce(item->>'postal','') !~ '^[0-9]{5}$' or length(coalesce(item->>'address','')) not between 5 and 250 then reason:='받는 분 이름·연락처·우편번호·주소를 확인해 주세요.';
  elsif coalesce(item->>'order_number','')<>'' and item->>'order_number' !~ '^GF-[0-9]{8}$' then reason:='주문번호 형식을 확인해 주세요.';
  else
   select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number','GF-'||lpad(o.order_no::text,8,'0'),'recipient_name',coalesce(nullif(o.recipient_name,''),o.customer_name),'customer_name',o.customer_name,'quantity',o.quantity,'version',o.version,'status',o.status,'existing',track=any(o.tracking_numbers) or track=o.tracking_number,'carrier',o.carrier,'replaceable',case when o.carrier in ('','한진','한진택배') then (select count(*) from unnest(case when cardinality(o.tracking_numbers)>0 then o.tracking_numbers else array[o.tracking_number] end) t where t<>'' and regexp_replace(t,'[[:space:]-]','','g') !~ '^[0-9]{12}$') else 0 end) order by o.created_at desc,o.id),'[]') into candidates
   from public.farmer_orders o
   where o.deleted_at is null and o.status<>'cancelled' and (not (o.pickup_requested or farmer_private.is_pickup_product(o.product_id)))
    and not exists(select 1 from farmer_private.gift_links g where g.order_id=o.id and g.claimed_at is null)
    and (coalesce(item->>'order_number','')='' or 'GF-'||lpad(o.order_no::text,8,'0')=item->>'order_number')
    and o.weight_grams=o.quantity::bigint*(item->>'weight_grams')::integer
    and o.postal_code=item->>'postal'
    and farmer_private.hanjin_address(item->>'address') in (farmer_private.hanjin_address(o.address),farmer_private.hanjin_address(o.address||' '||o.address_detail))
    and farmer_private.hanjin_mask(farmer_private.hanjin_name(coalesce(nullif(o.recipient_name,''),o.customer_name)),name_value)
    and farmer_private.hanjin_mask(regexp_replace(coalesce(nullif(o.recipient_phone,''),o.phone),'[[:space:]()-]','','g'),phone_value)
    and not exists(select 1 from public.farmer_orders other where other.id<>o.id and (track=any(other.tracking_numbers) or track=other.tracking_number));
   if jsonb_array_length(candidates)=0 then reason:='일치하는 주문이 없거나 다른 주문에 등록된 송장입니다.';end if;
  end if;
  result:=result||jsonb_build_array(jsonb_build_object('row',(item->>'row')::integer,'tracking',track,'name',item->>'name','weight_grams',item->>'weight_grams','candidates',candidates,'reason',reason));
 end loop;
 return jsonb_build_object('rows',result,'count',jsonb_array_length(p_rows));
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_admin_import_hanjin(p_request_id uuid, p_rows jsonb, p_matches jsonb, p_mark_shipped boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old farmer_private.hanjin_import_requests;actor_id uuid:=auth.uid();fp text;preview jsonb;item jsonb;line jsonb;candidate jsonb;
 rec record;o public.farmer_orders;original public.farmer_orders;tracking text[];incoming text;slot integer;used integer;additions integer:=0;
 changed integer:=0;advanced integer:=0;unchanged integer:=0;partial integer:=0;shipment_result jsonb;receipt jsonb;target text;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or p_mark_shipped is null then raise exception '등록 요청을 확인해 주세요.';end if;
 fp:=md5(jsonb_build_array(actor_id,p_rows,p_matches,p_mark_shipped)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into old from farmer_private.hanjin_import_requests where request_id=p_request_id;
 if found then if old.actor<>actor_id or old.fingerprint<>fp then raise exception '이미 사용한 요청 번호입니다.';end if;return old.receipt;end if;
 if p_matches is null or jsonb_typeof(p_matches)<>'array' or jsonb_array_length(p_matches) not between 1 and 500 or length(p_matches::text)>100000 then raise exception '등록할 행을 선택해 주세요.';end if;
 if exists(select 1 from jsonb_array_elements(p_matches) x where jsonb_typeof(x)<>'object' or coalesce(x->>'row','') !~ '^[1-9][0-9]{0,5}$' or coalesce(x->>'order_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(x->>'expected_version','') !~ '^[1-9][0-9]{0,15}$')
 or (select count(distinct x->>'row') from jsonb_array_elements(p_matches) x)<>jsonb_array_length(p_matches) then raise exception '선택한 행과 주문 정보를 확인해 주세요.';end if;
 -- Stable order locks, then the existing inventory lock used by status transitions.
 perform orders.id from public.farmer_orders orders join (select distinct (x->>'order_id')::uuid id from jsonb_array_elements(p_matches) x) chosen on chosen.id=orders.id order by orders.id for update of orders;
 -- Serialize duplicate waybills across distinct import requests, including different orders.
 for rec in select distinct x->>'tracking' tracking from jsonb_array_elements(p_rows) x order by 1 loop
  perform pg_advisory_xact_lock(hashtextextended('hanjin:'||rec.tracking,0));
 end loop;
 preview:=public.farmer_admin_hanjin_preview(p_rows);
 for item in select value from jsonb_array_elements(p_matches) loop
  select value into line from jsonb_array_elements(preview->'rows') where value->>'row'=item->>'row';
  if line is null or coalesce(line->>'reason','')<>'' then raise exception '일치하지 않는 행이 포함되어 있습니다. 파일을 다시 확인해 주세요.';end if;
  select value into candidate from jsonb_array_elements(line->'candidates') where value->>'id'=item->>'order_id';
  if candidate is null then raise exception '받는 분·연락처·주소가 일치하지 않는 주문입니다.';end if;
  if candidate->>'version'<>item->>'expected_version' then raise exception '다른 화면에서 주문이 변경되었습니다. 파일을 다시 확인해 주세요.';end if;
 end loop;
 for rec in select distinct (x->>'order_id')::uuid id from jsonb_array_elements(p_matches) x order by id loop
  select * into strict o from public.farmer_orders where id=rec.id;original:=o;
  tracking:=coalesce(o.tracking_numbers,'{}');
  if cardinality(tracking)=0 and o.tracking_number<>'' then tracking:=array[o.tracking_number];end if;
  if cardinality(tracking)>o.quantity then raise exception '기존 상자별 송장 정보를 먼저 확인해 주세요.';end if;
  while cardinality(tracking)<o.quantity loop tracking:=array_append(tracking,'');end loop;
  if exists(select 1 from unnest(tracking) t where t<>'' ) and o.carrier not in ('','한진','한진택배') then raise exception '다른 택배사 송장이 있는 주문입니다. 배송 정보를 먼저 확인해 주세요.';end if;
  -- Preserve genuine waybills (including legacy spacing/hyphens).
  tracking:=array(select case when regexp_replace(t,'[[:space:]-]','','g') ~ '^[0-9]{12}$' then regexp_replace(t,'[[:space:]-]','','g') else t end from unnest(tracking) with ordinality u(t,i) order by i);
  used:=0;
  for item in select x.value from jsonb_array_elements(p_rows) x where exists(select 1 from jsonb_array_elements(p_matches) m where m->>'row'=x.value->>'row' and (m->>'order_id')::uuid=o.id) order by (x.value->>'row')::integer loop
   incoming:=item->>'tracking';
   if not incoming=any(tracking) then
    select i into slot from generate_subscripts(tracking,1) i where tracking[i] !~ '^[0-9]{12}$' order by i limit 1;
    if slot is null then raise exception '주문 수량보다 송장 수가 많습니다. 기존 송장은 덮어쓰지 않습니다.';end if;
    tracking[slot]:=incoming;used:=used+1;
   end if;
  end loop;
  if tracking is distinct from o.tracking_numbers or o.carrier<>'한진' then
   update public.farmer_orders set tracking_numbers=tracking,tracking_number=coalesce((select t from unnest(tracking) with ordinality u(t,i) where t<>'' order by i limit 1),''),carrier='한진',version=version+1,updated_at=now() where id=o.id returning * into o;
  end if;
  -- Fully discounted orders need no payment; reserve stock once before shipment.
  if p_mark_shipped and o.status='pending' and o.total=0 and not exists(select 1 from unnest(tracking) t where t !~ '^[0-9]{12}$') then
   shipment_result:=public.farmer_admin_change_status(o.id,'confirmed',o.version,gen_random_uuid(),'','');
   select * into o from public.farmer_orders where id=o.id;
  end if;
  target:=case when o.status='confirmed' then 'shipped' else '' end;
  if p_mark_shipped and target<>'' and not exists(select 1 from unnest(tracking) t where t !~ '^[0-9]{12}$') then
   shipment_result:=public.farmer_admin_change_status(o.id,target,o.version,gen_random_uuid(),'한진',to_jsonb(tracking)::text);
   advanced:=advanced+1;select * into o from public.farmer_orders where id=o.id;
  elsif p_mark_shipped and target<>'' and exists(select 1 from unnest(tracking) t where t !~ '^[0-9]{12}$') then partial:=partial+1;
  end if;
  additions:=additions+used;
  if o.version=original.version then unchanged:=unchanged+1;
  else
   changed:=changed+1;
   insert into farmer_private.hanjin_import_orders values(p_request_id,o.id,original.version,o.version,original.tracking_numbers,tracking,original.status,o.status);
  end if;
 end loop;
 receipt:=jsonb_build_object('saved',true,'orders',changed,'parcels',additions,'shipped',advanced,'unchanged',unchanged,'partial',partial);
 insert into farmer_private.hanjin_import_requests(request_id,actor,fingerprint,receipt) values(p_request_id,actor_id,fp,receipt);
 return receipt;
end $function$;
