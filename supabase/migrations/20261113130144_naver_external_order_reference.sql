-- External provenance stays private; existing order APIs retain their current shape.
create table if not exists farmer_private.external_order_imports (
  order_id uuid primary key references public.farmer_orders(id),
  channel text not null check (channel = 'naver'),
  external_order_id text not null,
  external_product_order_id text not null,
  source_ordered_at timestamptz not null,
  source_paid_at timestamptz not null,
  source_payment jsonb not null check (jsonb_typeof(source_payment) = 'object'),
  imported_by uuid not null references auth.users(id),
  imported_at timestamptz not null default now(),
  unique (channel, external_product_order_id)
);
alter table farmer_private.external_order_imports enable row level security;
revoke all on farmer_private.external_order_imports from public, anon, authenticated;
