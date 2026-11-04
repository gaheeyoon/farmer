-- Apply the configured amount separately to every purchased box.
alter table farmer_private.discount_codes drop constraint discount_codes_mode_check;
alter table farmer_private.discount_codes add constraint discount_codes_mode_check check(mode in ('fixed','percent','product_unit','per_item'));

CREATE OR REPLACE FUNCTION public.farmer_admin_discount_save(p_request_id uuid, p_entry jsonb, p_expected_version bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare previous farmer_private.discount_requests; c farmer_private.discount_codes; fingerprint text; receipt jsonb;
 entry_id uuid; name text; kind text; value integer; rate integer; lim integer; product text; enabled boolean; exists_entry boolean;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or jsonb_typeof(p_entry) is distinct from 'object' then raise exception '저장할 할인코드를 확인해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array('save',auth.uid(),p_entry,p_expected_version)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.discount_requests where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 if coalesce(p_entry->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  or jsonb_typeof(p_entry->'active') is distinct from 'boolean'
  or coalesce(p_entry->>'amount','') !~ '^[0-9]{1,9}$' or coalesce(p_entry->>'percent','') !~ '^[0-9]{1,3}$' then raise exception '코드명과 할인 설정을 확인해 주세요.'; end if;
 entry_id:=(p_entry->>'id')::uuid;name:=upper(normalize(btrim(coalesce(p_entry->>'code','')),NFKC));kind:=p_entry->>'mode';
 value:=(p_entry->>'amount')::integer;rate:=(p_entry->>'percent')::integer;enabled:=(p_entry->>'active')::boolean;
 product:=nullif(p_entry->>'product_id','');
 if length(name) not between 1 and 40 or name ~ '[[:cntrl:]]' or kind is null or kind not in ('fixed','percent','product_unit','per_item')
  or (kind='percent' and (rate not between 1 and 100 or value<>0))
  or (kind<>'percent' and (value not between 1 and 100000000 or rate<>0)) then raise exception '코드명과 할인 금액을 확인해 주세요.'; end if;
 if kind='product_unit' then
  if not exists(select 1 from public.farmer_products where id=product and active) then raise exception '대상 상품을 선택해 주세요.'; end if;
 else product:=null; end if;
 if nullif(p_entry->>'usage_limit','') is not null then
  if (p_entry->>'usage_limit') !~ '^[0-9]{1,7}$' then raise exception '발급 수량을 확인해 주세요.'; end if;
  lim:=(p_entry->>'usage_limit')::integer;
  if lim not between 1 and 1000000 then raise exception '발급 수량을 확인해 주세요.'; end if;
 end if;
 -- Serialize creation for the same normalized name as well as edits to the same row.
 perform pg_advisory_xact_lock(hashtextextended('discount-name:'||name,0));
 select * into c from farmer_private.discount_codes where id=entry_id for update;exists_entry:=found;
 if exists_entry then
  if c.deleted_at is not null or p_expected_version is null or c.version<>p_expected_version then raise exception '다른 화면에서 할인코드가 변경되었습니다. 새로고침해 주세요.'; end if;
  if lim is not null and lim<farmer_private.discount_used(c.id) then raise exception '이미 사용한 수량보다 적게 설정할 수 없습니다.'; end if;
 elsif p_expected_version is not null then raise exception '수정할 할인코드가 없습니다. 새로고침해 주세요.';
 end if;
 if exists(select 1 from farmer_private.discount_codes where code=name and id<>entry_id) then raise exception '이미 등록된 코드명입니다. 삭제된 코드명도 다시 사용할 수 없습니다.'; end if;
 if exists_entry then
  update farmer_private.discount_codes set code=name,amount=value,percent=rate,mode=kind,product_id=product,usage_limit=lim,active=enabled,version=version+1,updated_at=now() where id=entry_id returning * into c;
 else
  insert into farmer_private.discount_codes(id,code,amount,percent,mode,product_id,usage_limit,active) values(entry_id,name,value,rate,kind,product,lim,enabled) returning * into c;
 end if;
 receipt:=jsonb_build_object('id',c.id,'version',c.version,'deleted',false);
 insert into farmer_private.discount_requests values(p_request_id,fingerprint,receipt,now());
 return receipt;
end $function$;

CREATE OR REPLACE FUNCTION public.farmer_quote_batch(p_deliveries jsonb, p_code text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item jsonb; p public.farmer_products; c farmer_private.discount_codes; lines jsonb:='[]'; line jsonb;
 subtotal integer:=0; discount integer:=0; remaining integer:=0; part integer; weight bigint:=0; qty integer; rate integer:=0;
 v_code text:=upper(normalize(btrim(coalesce(p_code,'')),NFKC)); eligible boolean:=false;
begin
 if jsonb_typeof(p_deliveries) is distinct from 'array' then raise exception '배송지를 추가해 주세요.'; end if;
 if jsonb_array_length(p_deliveries) not between 1 and 20 then raise exception '배송지는 한 번에 1~20곳까지 신청할 수 있습니다.'; end if;
 if length(v_code)>40 then raise exception '할인코드를 확인해 주세요.'; end if;
 if v_code<>'' then
  select * into c from farmer_private.discount_codes where code=v_code and active and deleted_at is null;
  if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
  if c.usage_limit is not null and farmer_private.discount_used(c.id)>=c.usage_limit then raise exception '사용 수량이 모두 소진된 할인코드입니다.'; end if;
  remaining:=c.amount;rate:=case when c.mode='percent' then c.percent else 0 end;
 end if;
 for item in select value from jsonb_array_elements(p_deliveries) loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception '상품과 수량을 확인해 주세요.'; end if;
  if item ? 'fulfillment_method' and (jsonb_typeof(item->'fulfillment_method')<>'string' or item->>'fulfillment_method' not in ('shipping','pickup')) then raise exception '수령 방법을 확인해 주세요.';end if;
  qty:=(item->>'quantity')::integer;
  if qty not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
  select * into p from public.farmer_products where id=item->>'product_id' and active;
  if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
  part:=0;
  if v_code<>'' then
   if c.mode='percent' then part:=floor(p.price::numeric*qty*c.percent/100)::integer;
   elsif c.mode='fixed' then part:=least(p.price*qty,remaining);remaining:=remaining-part;
   elsif c.mode='per_item' then part:=least(p.price,c.amount)*qty;
   elsif p.id=c.product_id and not eligible then part:=least(p.price,c.amount);eligible:=true;
   end if;
  end if;
  line:=jsonb_build_object('product_id',p.id,'product_name',p.name,'fulfillment_method',case when (farmer_private.is_pickup_product(p.id) or item->>'fulfillment_method'='pickup') then 'pickup' else 'shipping' end,'quantity',qty,'weight_grams',p.weight_grams*qty,
    'unit_price',p.price,'subtotal',p.price*qty,'discount_code',case when part>0 then v_code else null end,
    'discount_amount',part,'discount_percent',rate,'shipping_fee',0,'total',p.price*qty-part);
  lines:=lines||jsonb_build_array(line);subtotal:=subtotal+p.price*qty;discount:=discount+part;weight:=weight+p.weight_grams*qty;
 end loop;
 if v_code<>'' and c.mode='product_unit' and not eligible then raise exception '이 할인코드는 지정된 상품이 포함된 주문에 사용할 수 있습니다.'; end if;
 return jsonb_build_object('deliveries',lines,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,
 'discount_percent',rate,'shipping_fee',0,'weight_grams',weight,'total',subtotal-discount);
end $function$;
