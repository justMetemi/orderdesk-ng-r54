-- OrderDesk NG R5.1 · Universal Business Catalogue foundation
-- ADDITIVE ONLY. Run in a TEST Supabase project first. Do not run on production until reviewed.
-- Preserves existing products, orders, checkout, payment and subscription tables.
begin;

-- A product record can now represent any sellable item or service, without category lock-in.
alter table public.products
  add column if not exists item_type text not null default 'physical' check (item_type in ('physical','service','digital','custom')),
  add column if not exists sku text,
  add column if not exists barcode text,
  add column if not exists track_inventory boolean not null default true,
  add column if not exists custom_attributes jsonb not null default '{}'::jsonb,
  add column if not exists service_duration_minutes integer,
  add column if not exists booking_required boolean not null default false,
  add column if not exists digital_delivery_note text,
  add column if not exists fulfilment_methods text[] not null default array['delivery']::text[],
  add column if not exists is_bundle boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

create index if not exists products_business_item_type_idx on public.products(business_id,item_type);
create index if not exists products_business_sku_idx on public.products(business_id,sku) where sku is not null;

-- Flexible option groups and values (size, colour, flavour, storage, material, duration, etc.).
create table if not exists public.catalog_option_groups (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 80),
  is_required boolean not null default false,
  selection_mode text not null default 'single' check(selection_mode in ('single','multiple')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.catalog_option_values (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  group_id uuid not null references public.catalog_option_groups(id) on delete cascade,
  label text not null check(length(trim(label)) between 1 and 100),
  price_delta numeric(12,2) not null default 0,
  is_available boolean not null default true,
  sort_order integer not null default 0
);

-- Variant combinations are merchant-defined JSON option maps; no fixed clothing/food assumptions.
create table if not exists public.catalog_variants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  label text not null,
  option_values jsonb not null default '{}'::jsonb,
  sku text,
  barcode text,
  price numeric(12,2) check(price is null or price>=0),
  stock numeric(14,3) not null default 0 check(stock>=0),
  track_inventory boolean not null default true,
  image_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists catalog_variants_product_idx on public.catalog_variants(business_id,product_id,is_active);

-- Optional extras/modifiers: add-ons, toppings, accessories, service extras, gift wrap, etc.
create table if not exists public.catalog_modifier_groups (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  name text not null,
  is_required boolean not null default false,
  min_select integer not null default 0 check(min_select>=0),
  max_select integer not null default 1 check(max_select>=1),
  sort_order integer not null default 0
);
create table if not exists public.catalog_modifiers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  group_id uuid not null references public.catalog_modifier_groups(id) on delete cascade,
  name text not null,
  price numeric(12,2) not null default 0 check(price>=0),
  is_available boolean not null default true,
  sort_order integer not null default 0
);

-- Optional inventory batches/expiry and serial-number traceability.
create table if not exists public.inventory_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  batch_code text,
  quantity numeric(14,3) not null default 0 check(quantity>=0),
  received_at date,
  expires_at date,
  cost_per_unit numeric(12,2) check(cost_per_unit is null or cost_per_unit>=0),
  created_at timestamptz not null default now()
);
create table if not exists public.inventory_serials (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  serial_number text not null,
  status text not null default 'in_stock' check(status in ('in_stock','reserved','sold','returned','serviced')),
  created_at timestamptz not null default now(),
  unique(business_id,serial_number)
);

-- Bundle composition. A bundle can include multiple existing products.
create table if not exists public.catalog_bundle_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null default public.my_business() references public.businesses(id) on delete cascade,
  bundle_product_id uuid not null references public.products(id) on delete cascade,
  component_product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(14,3) not null default 1 check(quantity>0),
  unique(bundle_product_id,component_product_id)
);

-- Optional service appointments; standard product/order checkout remains unaffected.
create table if not exists public.service_bookings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  customer_email text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status text not null default 'requested' check(status in ('requested','confirmed','completed','cancelled','no_show')),
  customer_note text,
  created_at timestamptz not null default now(),
  check(ends_at is null or ends_at>starts_at)
);
create index if not exists service_bookings_business_time_idx on public.service_bookings(business_id,starts_at desc);

-- Preserve a line-item snapshot for future option-aware checkout without rewriting existing rows.
alter table public.store_order_items
  add column if not exists item_type text not null default 'physical',
  add column if not exists variant_id uuid references public.catalog_variants(id) on delete set null,
  add column if not exists selected_options jsonb not null default '{}'::jsonb,
  add column if not exists modifiers_snapshot jsonb not null default '[]'::jsonb,
  add column if not exists fulfilment_method text not null default 'delivery',
  add column if not exists sku_snapshot text;
alter table public.store_orders
  add column if not exists fulfilment_method text not null default 'delivery',
  add column if not exists delivery_zone_name text,
  add column if not exists delivery_eta_snapshot text;

-- Prevent cross-business references even if a client submits another merchant's UUID.
create or replace function public.enforce_catalog_business_scope()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare parent_business uuid;
begin
  if tg_table_name in ('catalog_option_groups','catalog_variants','catalog_modifier_groups','inventory_batches','inventory_serials','service_bookings') then
    if new.product_id is not null then select business_id into parent_business from public.products where id=new.product_id; if parent_business is distinct from new.business_id then raise exception 'Catalogue item does not belong to this business.'; end if; end if;
  elsif tg_table_name='catalog_option_values' then
    select business_id into parent_business from public.catalog_option_groups where id=new.group_id; if parent_business is distinct from new.business_id then raise exception 'Option group does not belong to this business.'; end if;
  elsif tg_table_name='catalog_modifiers' then
    select business_id into parent_business from public.catalog_modifier_groups where id=new.group_id; if parent_business is distinct from new.business_id then raise exception 'Modifier group does not belong to this business.'; end if;
  elsif tg_table_name='catalog_bundle_items' then
    select business_id into parent_business from public.products where id=new.bundle_product_id; if parent_business is distinct from new.business_id then raise exception 'Bundle does not belong to this business.'; end if;
    select business_id into parent_business from public.products where id=new.component_product_id; if parent_business is distinct from new.business_id then raise exception 'Bundle component does not belong to this business.'; end if;
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['catalog_option_groups','catalog_option_values','catalog_variants','catalog_modifier_groups','catalog_modifiers','inventory_batches','inventory_serials','catalog_bundle_items','service_bookings'] loop
    execute format('drop trigger if exists %I on public.%I',t||'_business_scope',t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.enforce_catalog_business_scope()',t||'_business_scope',t);
  end loop;
end $$;

-- Owner-only RLS. Every child row is tied to the same business as its parent.
do $$
declare t text;
begin
  foreach t in array array['catalog_option_groups','catalog_option_values','catalog_variants','catalog_modifier_groups','catalog_modifiers','inventory_batches','inventory_serials','catalog_bundle_items','service_bookings'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('drop policy if exists %I on public.%I',t||'_owner_all',t);
    execute format('create policy %I on public.%I for all to authenticated using (business_id=public.my_business()) with check (business_id=public.my_business())',t||'_owner_all',t);
    execute format('grant select,insert,update,delete on public.%I to authenticated',t);
  end loop;
end $$;

-- Platform-owner visibility: aggregate counts only; no customer data, order notes, or merchant secrets.
create or replace function public.owner_universal_catalog_overview()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare out jsonb;
begin
  if coalesce(public.owner_is_admin(),false) is not true then raise exception 'Not authorised.'; end if;
  select jsonb_build_object(
    'businesses_with_catalog', (select count(distinct business_id) from public.products),
    'catalog_items', (select count(*) from public.products),
    'physical_items', (select count(*) from public.products where item_type='physical'),
    'services', (select count(*) from public.products where item_type='service'),
    'digital_items', (select count(*) from public.products where item_type='digital'),
    'custom_items', (select count(*) from public.products where item_type='custom'),
    'variants', (select count(*) from public.catalog_variants),
    'modifier_groups', (select count(*) from public.catalog_modifier_groups),
    'bundles', (select count(*) from public.products where is_bundle=true),
    'tracked_batches', (select count(*) from public.inventory_batches),
    'serialised_units', (select count(*) from public.inventory_serials),
    'service_bookings', (select count(*) from public.service_bookings),
    'published_items', (select count(*) from public.products where store_published=true)
  ) into out;
  return out;
end $$;
revoke all on function public.owner_universal_catalog_overview() from public;
grant execute on function public.owner_universal_catalog_overview() to authenticated;

commit;
