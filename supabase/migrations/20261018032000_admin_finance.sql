-- Private accounting records. Actual farm expenses are imported separately, never shipped in public source.
create table farmer_private.finance_entries (
 id uuid primary key default gen_random_uuid(),
 occurred_on date not null check(occurred_on between date '2000-01-01' and date '2100-12-31'),
 direction text not null check(direction in ('income','expense')),
 category text not null check(length(category) between 1 and 40),
 title text not null check(length(title) between 1 and 120),
 counterparty text not null default '' check(length(counterparty)<=80),
 note text not null default '' check(length(note)<=1000),
 amount bigint not null check(amount between 1 and 1000000000),
 quantity numeric(12,3), unit_price bigint,
 version bigint not null default 1,
 source_key text unique,
 created_by uuid, updated_by uuid,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
 check((quantity is null and unit_price is null) or
       (quantity is not null and unit_price is not null and quantity>0 and quantity<=999999 and unit_price between 0 and 1000000000 and amount=round(quantity*unit_price)))
);
create index finance_entries_date on farmer_private.finance_entries(occurred_on desc,id) where deleted_at is null;
create table farmer_private.finance_requests (
 request_id uuid primary key, actor uuid not null, fingerprint text not null,
 receipt jsonb not null, created_at timestamptz not null default now()
);
alter table farmer_private.finance_entries enable row level security;
alter table farmer_private.finance_requests enable row level security;
revoke all on farmer_private.finance_entries,farmer_private.finance_requests from public,anon,authenticated;
create index farmer_paid_order_date on public.farmer_orders((coalesce(confirmed_at,created_at)))
 where order_kind='sale' and status in ('confirmed','shipped','delivered');

create function public.farmer_admin_finance_report(p_year integer,p_kind text default '',p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; starts timestamptz; ends timestamptz;
begin
 perform farmer_private.require_admin();
 if p_year is null or p_year not between 2000 and 2100 or coalesce(p_kind,'') not in ('','income','expense')
   or length(coalesce(p_search,''))>100 or p_offset is null or p_offset not between 0 and 1000000 then raise exception '조회 조건을 확인해 주세요.'; end if;
 starts:=make_timestamptz(p_year,1,1,0,0,0,'Asia/Seoul');ends:=make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Seoul');
 with paid as (
  select * from public.farmer_orders o where o.order_kind='sale' and o.status in ('confirmed','shipped','delivered')
   and coalesce(o.confirmed_at,o.created_at)>=starts and coalesce(o.confirmed_at,o.created_at)<ends
 ), ledger as (
  select 'manual'::text as source,e.id,e.occurred_on,e.direction,e.category,e.title,e.counterparty,e.note,e.amount,
    e.quantity,e.unit_price,e.version,null::text as order_number
  from farmer_private.finance_entries e where e.deleted_at is null and e.occurred_on>=make_date(p_year,1,1) and e.occurred_on<make_date(p_year+1,1,1)
  union all
  select 'order',o.id,(coalesce(o.confirmed_at,o.created_at) at time zone 'Asia/Seoul')::date,'income','고구마 판매',
    o.product_name||' × '||o.quantity::text,o.customer_name,
    case o.status when 'confirmed' then '입금 확인(배송 준비)' when 'shipped' then '배송 중' else '배송 완료' end,
    o.total::bigint,o.quantity::numeric,o.unit_price::bigint,o.version,'GF-'||lpad(o.order_no::text,8,'0')
  from paid o
 ), filtered as (
  select * from ledger l where (coalesce(p_kind,'')='' or l.direction=p_kind)
   and (coalesce(p_search,'')='' or position(lower(p_search) in lower(l.title||' '||l.category||' '||l.counterparty||' '||l.note||' '||coalesce(l.order_number,'')))>0)
 ), monthly as (
  select m as month,coalesce(sum(l.amount) filter(where l.direction='income'),0) as income,
    coalesce(sum(l.amount) filter(where l.direction='expense'),0) as expense
  from generate_series(1,12) m left join ledger l on extract(month from l.occurred_on)=m group by m
 )
 select jsonb_build_object('year',p_year,'summary',jsonb_build_object(
   'order_income',coalesce((select sum(total) from paid),0),
   'manual_income',coalesce((select sum(amount) from ledger where source='manual' and direction='income'),0),
   'expense',coalesce((select sum(amount) from ledger where direction='expense'),0),
   'profit',coalesce((select sum(case when direction='income' then amount else -amount end) from ledger),0),
   'order_count',(select count(*) from paid),'sold_kg',coalesce((select sum(weight_grams)::numeric/1000 from paid),0),
   'collected_shipping',coalesce((select sum(shipping_fee) from paid),0),
   'pending_income',coalesce((select sum(total) from public.farmer_orders where order_kind='sale' and status='pending' and created_at>=starts and created_at<ends),0)),
   'categories',coalesce((select jsonb_agg(to_jsonb(t) order by t.amount desc,t.category) from
      (select category,sum(amount) as amount from ledger where direction='expense' group by category)t),'[]'::jsonb),
   'months',(select jsonb_agg(to_jsonb(m) order by m.month) from monthly m),
   'entries',coalesce((select jsonb_agg(to_jsonb(t) order by t.occurred_on desc,t.source,t.id) from
      (select * from filtered order by occurred_on desc,source,id limit 50 offset p_offset)t),'[]'::jsonb),
   'total',(select count(*) from filtered),'offset',p_offset,'limit',50) into result;
 return result;
end $$;

create function public.farmer_admin_finance_save(p_request_id uuid,p_entry jsonb,p_expected_version bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare previous farmer_private.finance_requests; e farmer_private.finance_entries; entry_id uuid; actor_id uuid:=auth.uid();
 fingerprint text; receipt jsonb; day date; kind text; category_value text; title_value text; party text; memo text;
 amount_value bigint; qty numeric; price bigint; exists_entry boolean;
begin
 perform farmer_private.require_admin();
 if p_request_id is null or jsonb_typeof(p_entry) is distinct from 'object' then raise exception '저장할 내역을 확인해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array('save',actor_id,p_entry,p_expected_version)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.finance_requests where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다. 새 내역으로 다시 시도해 주세요.'; end if;
  return previous.receipt;
 end if;
 if coalesce(p_entry->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or coalesce(p_entry->>'occurred_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   or coalesce(p_entry->>'amount','') !~ '^[0-9]{1,10}$' then raise exception '날짜와 금액을 확인해 주세요.'; end if;
 entry_id:=(p_entry->>'id')::uuid;
 begin day:=(p_entry->>'occurred_on')::date; exception when others then raise exception '날짜를 확인해 주세요.'; end;
 kind:=p_entry->>'direction';category_value:=btrim(coalesce(p_entry->>'category',''));title_value:=btrim(coalesce(p_entry->>'title',''));
 party:=btrim(coalesce(p_entry->>'counterparty',''));memo:=btrim(coalesce(p_entry->>'note',''));amount_value:=(p_entry->>'amount')::bigint;
 if day not between date '2000-01-01' and date '2100-12-31' or kind is null or kind not in ('income','expense')
   or length(category_value) not between 1 and 40 or length(title_value) not between 1 and 120 or length(party)>80
   or length(memo)>1000 or amount_value not between 1 and 1000000000 then raise exception '내역의 항목과 금액을 확인해 주세요.'; end if;
 if nullif(p_entry->>'quantity','') is not null or nullif(p_entry->>'unit_price','') is not null then
  if coalesce(p_entry->>'quantity','') !~ '^[0-9]{1,6}(\.[0-9]{1,3})?$'
    or coalesce(p_entry->>'unit_price','') !~ '^[0-9]{1,10}$' then raise exception '수량과 단가를 함께 확인해 주세요.'; end if;
  qty:=(p_entry->>'quantity')::numeric;price:=(p_entry->>'unit_price')::bigint;
  if qty<=0 or qty>999999 or price>1000000000 or round(qty*price)<>amount_value then raise exception '수량 × 단가와 금액이 일치해야 합니다.'; end if;
 end if;
 select * into e from farmer_private.finance_entries where id=entry_id for update;exists_entry:=found;
 if exists_entry then
  if e.deleted_at is not null or p_expected_version is null or p_expected_version<>e.version then raise exception '다른 화면에서 내역이 변경되었습니다. 새로고침해 주세요.'; end if;
  update farmer_private.finance_entries set occurred_on=day,direction=kind,category=category_value,title=title_value,
   counterparty=party,note=memo,amount=amount_value,quantity=qty,unit_price=price,version=version+1,updated_by=actor_id,updated_at=now()
   where id=entry_id returning * into e;
 else
  if p_expected_version is not null then raise exception '수정할 내역이 없습니다. 새로고침해 주세요.'; end if;
  insert into farmer_private.finance_entries(id,occurred_on,direction,category,title,counterparty,note,amount,quantity,unit_price,created_by,updated_by)
   values(entry_id,day,kind,category_value,title_value,party,memo,amount_value,qty,price,actor_id,actor_id) returning * into e;
 end if;
 receipt:=jsonb_build_object('id',e.id,'version',e.version,'deleted',false);
 insert into farmer_private.finance_requests(request_id,actor,fingerprint,receipt) values(p_request_id,actor_id,fingerprint,receipt);
 return receipt;
end $$;

create function public.farmer_admin_finance_delete(p_entry_id uuid,p_expected_version bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e farmer_private.finance_entries; previous farmer_private.finance_requests; fingerprint text; receipt jsonb; actor_id uuid:=auth.uid();
begin
 perform farmer_private.require_admin();
 if p_entry_id is null or p_request_id is null or p_expected_version is null then raise exception '삭제할 내역을 확인해 주세요.'; end if;
 fingerprint:=md5(jsonb_build_array('delete',actor_id,p_entry_id,p_expected_version)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 select * into previous from farmer_private.finance_requests where request_id=p_request_id;
 if found then
  if previous.fingerprint<>fingerprint then raise exception '이미 사용한 요청 번호입니다.'; end if;
  return previous.receipt;
 end if;
 select * into e from farmer_private.finance_entries where id=p_entry_id for update;
 if not found or e.deleted_at is not null or e.version<>p_expected_version then raise exception '다른 화면에서 내역이 변경되었습니다. 새로고침해 주세요.'; end if;
 update farmer_private.finance_entries set deleted_at=now(),updated_at=now(),updated_by=actor_id,version=version+1 where id=e.id returning * into e;
 receipt:=jsonb_build_object('id',e.id,'version',e.version,'deleted',true);
 insert into farmer_private.finance_requests(request_id,actor,fingerprint,receipt) values(p_request_id,actor_id,fingerprint,receipt);
 return receipt;
end $$;
revoke all on function public.farmer_admin_finance_report(integer,text,text,integer),public.farmer_admin_finance_save(uuid,jsonb,bigint),public.farmer_admin_finance_delete(uuid,bigint,uuid) from public,anon,authenticated;
grant execute on function public.farmer_admin_finance_report(integer,text,text,integer),public.farmer_admin_finance_save(uuid,jsonb,bigint),public.farmer_admin_finance_delete(uuid,bigint,uuid) to authenticated;
