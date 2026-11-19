-- OrderDesk NG R5.2.2 — Service bookings and secure digital fulfilment
-- Additive migration. Do NOT rerun R5.1 or R5.2 migrations.
begin;

-- Merchant-managed delivery content is private. Store a secure download URL, access code,
-- licence key, or delivery instructions here; it is never included in public catalogue data.
create table if not exists public.catalog_digital_assets (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null unique references public.products(id) on delete cascade,
  delivery_content text not null check (length(trim(delivery_content)) between 1 and 20000),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.catalog_digital_assets enable row level security;
drop policy if exists catalog_digital_assets_owner_all on public.catalog_digital_assets;
create policy catalog_digital_assets_owner_all on public.catalog_digital_assets
  for all to authenticated using (business_id=public.my_business())
  with check (business_id=public.my_business());
grant select,insert,update,delete on public.catalog_digital_assets to authenticated;
revoke all on public.catalog_digital_assets from anon;

-- Immutable order-time snapshot. RLS intentionally denies direct customer/merchant table reads;
-- customers use the phone + order-reference RPC below.
create table if not exists public.store_order_digital_deliveries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  store_order_id uuid not null references public.store_orders(id) on delete cascade,
  store_order_item_id uuid not null references public.store_order_items(id) on delete cascade,
  product_name text not null,
  delivery_content text not null,
  created_at timestamptz not null default now(),
  unique(store_order_item_id)
);
alter table public.store_order_digital_deliveries enable row level security;
revoke all on public.store_order_digital_deliveries from public,anon,authenticated;

-- Connect each appointment to the exact store order and line item.
alter table public.service_bookings
  add column if not exists store_order_id uuid references public.store_orders(id) on delete set null,
  add column if not exists store_order_item_id uuid references public.store_order_items(id) on delete set null,
  add column if not exists requested_at timestamptz,
  add column if not exists merchant_note text;
create index if not exists service_bookings_order_idx on public.service_bookings(store_order_id);
create unique index if not exists service_bookings_order_item_uidx
  on public.service_bookings(store_order_item_id) where store_order_item_id is not null;


create or replace function public.get_public_catalog_options(p_slug text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object(
  'product_id',p.id,
  'item_type',p.item_type,
  'booking_required',coalesce(p.booking_required,false),
  'service_duration_minutes',p.service_duration_minutes,
  'variants',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'label',v.label,'option_values',v.option_values,'price',v.price,'stock',v.stock,'track_inventory',v.track_inventory,'sku',v.sku,'image_url',v.image_url) order by v.label) from public.catalog_variants v where v.product_id=p.id and v.business_id=p.business_id and v.is_active),'[]'::jsonb),
  'option_groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'is_required',g.is_required,'selection_mode',g.selection_mode,'values',coalesce((select jsonb_agg(jsonb_build_object('id',ov.id,'label',ov.label,'price_delta',ov.price_delta) order by ov.sort_order,ov.label) from public.catalog_option_values ov where ov.group_id=g.id and ov.is_available),'[]'::jsonb)) order by g.sort_order,g.name) from public.catalog_option_groups g where g.product_id=p.id and g.business_id=p.business_id),'[]'::jsonb),
  'modifier_groups',coalesce((select jsonb_agg(jsonb_build_object('id',mg.id,'name',mg.name,'is_required',mg.is_required,'min_select',mg.min_select,'max_select',mg.max_select,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'price',m.price) order by m.sort_order,m.name) from public.catalog_modifiers m where m.group_id=mg.id and m.is_available),'[]'::jsonb)) order by mg.sort_order,mg.name) from public.catalog_modifier_groups mg where mg.product_id=p.id and mg.business_id=p.business_id),'[]'::jsonb),
  'bundle_items',coalesce((select jsonb_agg(jsonb_build_object('product_id',bi.component_product_id,'name',cp.name,'quantity',bi.quantity)) from public.catalog_bundle_items bi join public.products cp on cp.id=bi.component_product_id where bi.bundle_product_id=p.id),'[]'::jsonb)
 ), '[]'::jsonb)
 from public.products p join public.businesses b on b.id=p.business_id
 where lower(b.shop_slug)=lower(trim(p_slug)) and b.store_enabled and p.store_published
 $$;
revoke all on function public.get_public_catalog_options(text) from public;
grant execute on function public.get_public_catalog_options(text) to anon,authenticated;

-- A single trigger creates the booking or digital-delivery snapshot inside the same
-- transaction as checkout, for both Paystack and bank-transfer / pay-on-delivery paths.
create or replace function public.create_universal_fulfilment_for_order_item()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
  p public.products%rowtype;
  o public.store_orders%rowtype;
  start_at timestamptz;
  duration_mins integer;
  asset text;
begin
  select * into p from public.products where id=new.product_id;
  select * into o from public.store_orders where id=new.store_order_id;
  if not found or p.id is null then return new; end if;

  if coalesce(new.item_type,p.item_type)='digital' then
    if o.payment_method='Pay on delivery' then
      raise exception 'Digital products require Paystack or bank transfer; pay on delivery is not available.';
    end if;
    select delivery_content into asset
      from public.catalog_digital_assets
      where business_id=o.business_id and product_id=p.id;
    if asset is null or length(trim(asset))=0 then
      raise exception 'Digital delivery is not configured for "%". Ask the store owner to finish its digital delivery setup.',p.name;
    end if;
    insert into public.store_order_digital_deliveries(
      business_id,store_order_id,store_order_item_id,product_name,delivery_content
    ) values (o.business_id,o.id,new.id,p.name,asset);
  elsif coalesce(new.item_type,p.item_type)='service' and coalesce(p.booking_required,false) then
    begin
      start_at := nullif(new.selected_options->>'appointment_start','')::timestamptz;
    exception when others then
      raise exception 'Choose a valid appointment date and time for "%".',p.name;
    end;
    if start_at is null or start_at <= now() then
      raise exception 'Choose a future appointment date and time for "%".',p.name;
    end if;
    duration_mins := greatest(1,coalesce(p.service_duration_minutes,60));
    insert into public.service_bookings(
      business_id,product_id,customer_name,customer_phone,customer_email,
      starts_at,ends_at,status,customer_note,store_order_id,store_order_item_id,requested_at
    ) values (
      o.business_id,p.id,o.customer_name,o.customer_phone,o.customer_email,
      start_at,start_at+make_interval(mins=>duration_mins),'requested',
      coalesce(o.customer_note,''),o.id,new.id,now()
    );
  end if;
  return new;
end $$;

drop trigger if exists store_order_item_universal_fulfilment on public.store_order_items;
create trigger store_order_item_universal_fulfilment
  after insert on public.store_order_items
  for each row execute function public.create_universal_fulfilment_for_order_item();

-- Customers can retrieve digital delivery only after the order payment has been confirmed.
-- Random order references plus phone verification are required. Cancelled orders never disclose it.
create or replace function public.get_public_order_digital_delivery(
  p_order_ref text, p_customer_phone text
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if length(trim(coalesce(p_order_ref,'')))<6
     or length(regexp_replace(coalesce(p_customer_phone,''),'\D','','g'))<7 then
    raise exception 'Enter your order reference and the phone number used at checkout.';
  end if;
  select jsonb_build_object(
    'order_ref',o.order_ref,
    'payment_status',o.payment_status,
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_name',d.product_name,
        'delivery_content',d.delivery_content
      ) order by d.created_at)
      from public.store_order_digital_deliveries d
      where d.store_order_id=o.id
    ),'[]'::jsonb)
  ) into result
  from public.store_orders o
  where upper(o.order_ref)=upper(trim(p_order_ref))
    and right(regexp_replace(coalesce(o.customer_phone,''),'\D','','g'),10)
        =right(regexp_replace(coalesce(p_customer_phone,''),'\D','','g'),10)
    and o.status<>'Cancelled'
    and o.payment_status='Confirmed'
    and o.payment_method in ('Paystack','Bank transfer')
  limit 1;
  if result is null then
    raise exception 'No paid digital order was found. Check your details or wait for the store to confirm your bank transfer.';
  end if;
  if jsonb_array_length(result->'items')=0 then
    raise exception 'This order has no digital items.';
  end if;
  return result;
end $$;
revoke all on function public.get_public_order_digital_delivery(text,text) from public;
grant execute on function public.get_public_order_digital_delivery(text,text) to anon,authenticated;


-- Digital-only purchases have no delivery charge. The storefront also displays zero.
create or replace function public.zero_delivery_for_digital_only_order()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if lower(trim(coalesce(new.delivery_address,'')))='digital delivery' then
    new.delivery_fee:=0;
    new.total:=new.subtotal;
  end if;
  return new;
end $$;
drop trigger if exists store_order_digital_delivery_fee on public.store_orders;
create trigger store_order_digital_delivery_fee
  before insert on public.store_orders
  for each row execute function public.zero_delivery_for_digital_only_order();

-- If an order is cancelled, its appointment requests are cancelled as well.
create or replace function public.sync_service_booking_order_status()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status='Cancelled' and old.status is distinct from new.status then
    update public.service_bookings set status='cancelled'
    where store_order_id=new.id and status in ('requested','confirmed');
  end if;
  return new;
end $$;
drop trigger if exists store_order_cancel_service_bookings on public.store_orders;
create trigger store_order_cancel_service_bookings
  after update of status on public.store_orders
  for each row execute function public.sync_service_booking_order_status();



-- Prevent two confirmed appointments from occupying the same merchant time window.
create or replace function public.prevent_confirmed_service_booking_overlap()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status='confirmed' and new.ends_at is not null then
    if exists (
      select 1 from public.service_bookings b
      where b.business_id=new.business_id
        and b.id<>new.id
        and b.status='confirmed'
        and b.starts_at < new.ends_at
        and coalesce(b.ends_at,b.starts_at+interval '60 minutes') > new.starts_at
    ) then
      raise exception 'This time slot overlaps another confirmed appointment. Choose another time.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists service_booking_no_confirmed_overlap on public.service_bookings;
create trigger service_booking_no_confirmed_overlap
  before insert or update of starts_at,ends_at,status on public.service_bookings
  for each row execute function public.prevent_confirmed_service_booking_overlap();



-- Prevent a merchant from attaching a digital delivery asset to another business's product.
create or replace function public.enforce_digital_asset_business_scope()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare product_business uuid;
begin
  select business_id into product_business from public.products where id=new.product_id;
  if product_business is null or product_business is distinct from new.business_id then
    raise exception 'Digital product must belong to your business.';
  end if;
  return new;
end $$;
drop trigger if exists catalog_digital_asset_business_scope on public.catalog_digital_assets;
create trigger catalog_digital_asset_business_scope
  before insert or update on public.catalog_digital_assets
  for each row execute function public.enforce_digital_asset_business_scope();


commit;
