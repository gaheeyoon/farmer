-- Reviews are separate from orders. No order, stock or payment state is changed.
create table farmer_private.reviews (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique, fingerprint text not null,
  display_name text not null check(length(display_name) between 1 and 20),
  body text not null check(length(body) between 1 and 1200),
  photo_count integer not null check(photo_count between 0 and 3),
  upload_token uuid not null default gen_random_uuid(),
  status text not null default 'draft' check(status in ('draft','published','hidden','expired')),
  created_at timestamptz not null default now(), published_at timestamptz,
  upload_until timestamptz not null default now()+interval '30 minutes',
  version bigint not null default 1, moderated_by uuid, updated_at timestamptz not null default now()
);
create index farmer_reviews_feed on farmer_private.reviews(published_at desc,id) where status='published';
create table farmer_private.review_attempts (
  bucket text primary key, attempts integer not null default 1,
  window_started timestamptz not null default now()
);
alter table farmer_private.reviews enable row level security;
alter table farmer_private.review_attempts enable row level security;
revoke all on farmer_private.reviews,farmer_private.review_attempts from public,anon,authenticated;

create function farmer_private.review_photo_paths(r farmer_private.reviews) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(r.id::text||'/'||r.upload_token::text||'/'||n::text||'.jpg' order by n),'[]'::jsonb)
  from generate_series(1,r.photo_count) n;
$$;
revoke all on function farmer_private.review_photo_paths(farmer_private.reviews) from public,anon,authenticated;

create function public.farmer_review_begin(p_request_id uuid,p_display_name text,p_body text,p_photo_count integer,p_consent boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r farmer_private.reviews; signature text; nickname text; attempts_value integer; peer text; b record;
begin
  nickname:=coalesce(nullif(btrim(p_display_name),''),'고구맙습니다 구매자');
  if p_request_id is null or p_consent is distinct from true or length(nickname)>20
     or length(btrim(coalesce(p_body,''))) not between 1 and 1200 or p_photo_count is null or p_photo_count not between 0 and 3 then
    return jsonb_build_object('ok',false,'message','이야기와 공개 동의를 확인해 주세요. 사진은 최대 3장입니다.');
  end if;
  signature:=md5(jsonb_build_array(nickname,btrim(p_body),p_photo_count)::text);
  perform pg_advisory_xact_lock(hashtextextended('review:'||p_request_id::text,0));
  select * into r from farmer_private.reviews where request_id=p_request_id;
  if found then
    if r.fingerprint<>signature then return jsonb_build_object('ok',false,'message','이미 사용한 작성 요청입니다. 다시 작성해 주세요.'); end if;
    if r.status='published' then return jsonb_build_object('ok',true,'id',r.id,'published',true); end if;
    if r.status<>'draft' or r.upload_until<now() then return jsonb_build_object('ok',false,'message','작성 시간이 지났습니다. 다시 작성해 주세요.'); end if;
    return jsonb_build_object('ok',true,'id',r.id,'upload_token',r.upload_token,'paths',farmer_private.review_photo_paths(r));
  end if;
  -- Only a hash is retained for a short request-limit window, never an address or contact.
  peer:=btrim(split_part(coalesce((coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb)->>'x-forwarded-for','shared'),',',-1));
  delete from farmer_private.review_attempts where window_started<now()-interval '1 day';
  for b in select * from (values ('peer:'||md5(peer),10,interval '15 minutes'),('daily',100,interval '1 day')) as bounds(bucket,maximum,period) loop
    insert into farmer_private.review_attempts(bucket) values(b.bucket)
    on conflict(bucket) do update set
      attempts=case when review_attempts.window_started<now()-b.period then 1 else least(review_attempts.attempts+1,10000) end,
      window_started=case when review_attempts.window_started<now()-b.period then now() else review_attempts.window_started end
    returning attempts into attempts_value;
    if attempts_value>b.maximum then return jsonb_build_object('ok',false,'message','작성 요청이 많습니다. 잠시 뒤 다시 시도해 주세요.'); end if;
  end loop;
  insert into farmer_private.reviews(request_id,fingerprint,display_name,body,photo_count)
  values(p_request_id,signature,nickname,btrim(p_body),p_photo_count) returning * into r;
  return jsonb_build_object('ok',true,'id',r.id,'upload_token',r.upload_token,'paths',farmer_private.review_photo_paths(r));
end $$;

create function public.farmer_review_publish(p_id uuid,p_upload_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r farmer_private.reviews; path text;
begin
  select * into r from farmer_private.reviews where id=p_id and upload_token=p_upload_token for update;
  if not found then raise exception '작성 요청을 확인할 수 없습니다.'; end if;
  if r.status='published' then return jsonb_build_object('ok',true,'id',r.id); end if;
  if r.status<>'draft' or r.upload_until<now() then raise exception '작성 시간이 지났습니다. 다시 작성해 주세요.'; end if;
  for path in select jsonb_array_elements_text(farmer_private.review_photo_paths(r)) loop
    if not exists(select 1 from storage.objects where bucket_id='farmer-reviews' and name=path
      and metadata->>'mimetype'='image/jpeg' and (metadata->>'size')::bigint between 1 and 1500000) then
      raise exception '사진 업로드가 끝나지 않았습니다. 다시 등록해 주세요.';
    end if;
  end loop;
  update farmer_private.reviews set status='published',published_at=now(),updated_at=now(),version=version+1 where id=r.id;
  return jsonb_build_object('ok',true,'id',r.id);
end $$;

create function public.farmer_reviews(p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; total_value bigint;
begin
  if p_offset is null or p_offset not between 0 and 100000 then raise exception '조회 범위를 확인해 주세요.'; end if;
  select count(*) into total_value from farmer_private.reviews where status='published';
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'display_name',r.display_name,'body',r.body,
    'published_at',r.published_at,'photos',farmer_private.review_photo_paths(r)) order by r.published_at desc,r.id),'[]') into result
  from (select * from farmer_private.reviews where status='published' order by published_at desc,id limit 9 offset p_offset) r;
  return jsonb_build_object('reviews',result,'total',total_value,'next_offset',case when p_offset+9<total_value then p_offset+9 else null end);
end $$;

create function farmer_private.review_storage_allowed(p_name text,p_write boolean) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from farmer_private.reviews r
    where p_name in (select jsonb_array_elements_text(farmer_private.review_photo_paths(r)))
      and ((p_write and r.status='draft' and r.upload_until>now()) or (not p_write and r.status='published')));
$$;
revoke all on function farmer_private.review_storage_allowed(text,boolean) from public,anon,authenticated;
grant usage on schema farmer_private to anon,authenticated;
grant execute on function farmer_private.review_storage_allowed(text,boolean) to anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('farmer-reviews','farmer-reviews',false,1500000,array['image/jpeg']);
create policy farmer_review_image_insert on storage.objects for insert to anon,authenticated
with check(bucket_id='farmer-reviews' and farmer_private.review_storage_allowed(name,true));
create policy farmer_review_image_read on storage.objects for select to anon,authenticated
using(bucket_id='farmer-reviews' and farmer_private.review_storage_allowed(name,false));

create function public.farmer_admin_reviews(p_status text default '',p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; total_value bigint;
begin
  perform farmer_private.require_admin();
  if p_status is null or p_status not in ('','published','hidden') or p_offset is null or p_offset not between 0 and 100000 then raise exception '조회 조건을 확인해 주세요.'; end if;
  select count(*) into total_value from farmer_private.reviews where status in ('published','hidden') and (p_status='' or status=p_status);
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'display_name',r.display_name,'body',r.body,
    'published_at',r.published_at,'photo_count',r.photo_count,'status',r.status,'version',r.version)
    order by r.published_at desc,r.id),'[]') into result
  from (select * from farmer_private.reviews where status in ('published','hidden') and (p_status='' or status=p_status)
    order by published_at desc,id limit 20 offset p_offset) r;
  return jsonb_build_object('reviews',result,'total',total_value,'next_offset',case when p_offset+20<total_value then p_offset+20 else null end);
end $$;
create function public.farmer_admin_review_visibility(p_id uuid,p_status text,p_version bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r farmer_private.reviews;
begin
  perform farmer_private.require_admin();
  if p_status is null or p_status not in ('published','hidden') then raise exception '공개 상태를 확인해 주세요.'; end if;
  select * into r from farmer_private.reviews where id=p_id and status in ('published','hidden') for update;
  if not found then raise exception '후기를 찾을 수 없습니다.'; end if;
  if r.status=p_status then return jsonb_build_object('ok',true); end if;
  if p_version is null or r.version<>p_version then raise exception '후기가 변경되었습니다. 새로고침해 주세요.'; end if;
  update farmer_private.reviews set status=p_status,moderated_by=auth.uid(),updated_at=now(),version=version+1 where id=r.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.farmer_review_begin(uuid,text,text,integer,boolean),public.farmer_review_publish(uuid,uuid),public.farmer_reviews(integer) from public,anon,authenticated;
grant execute on function public.farmer_review_begin(uuid,text,text,integer,boolean),public.farmer_review_publish(uuid,uuid),public.farmer_reviews(integer) to anon,authenticated;
revoke all on function public.farmer_admin_reviews(text,integer),public.farmer_admin_review_visibility(uuid,text,bigint) from public,anon,authenticated;
grant execute on function public.farmer_admin_reviews(text,integer),public.farmer_admin_review_visibility(uuid,text,bigint) to authenticated;
