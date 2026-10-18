-- New quotes use the updated prices and free shipping. Saved orders keep their original amounts.
update public.farmer_products set price=12000 where id='hopungmi-2kg';
update public.farmer_products set price=22000 where id='hopungmi-5kg';
alter table public.farmer_orders alter column shipping_fee set default 0;

create or replace function farmer_private.quote(p_product_id text,p_quantity integer,p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.farmer_products; discount integer:=0; rate integer:=0; v_code text:=upper(btrim(coalesce(p_code,''))); subtotal integer;
begin
  if p_quantity is null or p_quantity not between 1 and 99 then raise exception '수량은 1~99개로 선택해 주세요.'; end if;
  select * into p from public.farmer_products where id=p_product_id and active;
  if not found then raise exception '판매 중인 상품을 선택해 주세요.'; end if;
  subtotal:=p.price*p_quantity;
  if v_code<>'' then
    select amount,percent into discount,rate from farmer_private.discount_codes where discount_codes.code=v_code and active;
    if not found then raise exception '사용할 수 없는 할인코드입니다.'; end if;
  end if;
  discount:=least(subtotal,case when rate>0 then floor(subtotal::numeric*rate/100)::integer else discount end);
  return jsonb_build_object('product_id',p.id,'product_name',p.name,'quantity',p_quantity,'weight_grams',p.weight_grams*p_quantity,
    'unit_price',p.price,'subtotal',subtotal,'discount_code',nullif(v_code,''),'discount_amount',discount,'discount_percent',rate,'shipping_fee',0,'total',subtotal-discount);
end $$;

create or replace function public.farmer_catalog() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('products',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'weight_grams',p.weight_grams,'price',p.price,'available',i.available_grams>=p.weight_grams) order by p.weight_grams),'[]'::jsonb) from public.farmer_products p cross join public.farmer_inventory i where p.active), 'shipping_fee',0);
$$;

-- Preserve the existing API access model.
revoke all on function farmer_private.quote(text,integer,text) from public,anon,authenticated;
revoke all on function public.farmer_catalog() from public,anon,authenticated;
grant execute on function public.farmer_catalog() to anon,authenticated;
