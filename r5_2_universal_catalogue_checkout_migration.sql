-- OrderDesk NG R5.2 universal catalogue checkout integration
-- Additive: does NOT rerun or alter r5_1_universal_business_upgrade.sql.
begin;

create table if not exists public.store_order_inventory_allocations (
 id uuid primary key default gen_random_uuid(), store_order_id uuid not null references public.store_orders(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict,
 variant_id uuid references public.catalog_variants(id) on delete set null,
 quantity numeric(14,3) not null check(quantity>0), allocation_kind text not null check(allocation_kind in ('product','variant','bundle_component'))
);
create index if not exists store_order_inventory_allocations_order_idx on public.store_order_inventory_allocations(store_order_id);
alter table public.store_order_inventory_allocations enable row level security;
revoke all on public.store_order_inventory_allocations from public,anon,authenticated;

create table if not exists public.store_delivery_zones (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null, fee numeric(12,2) not null default 0 check(fee>=0), is_active boolean not null default true,
 created_at timestamptz not null default now(), unique(business_id,name)
);
alter table public.store_delivery_zones enable row level security;
drop policy if exists store_delivery_zones_owner_all on public.store_delivery_zones;
create policy store_delivery_zones_owner_all on public.store_delivery_zones for all to authenticated
 using(business_id=public.my_business()) with check(business_id=public.my_business());
grant select,insert,update,delete on public.store_delivery_zones to authenticated;

alter table public.store_order_items
 add column if not exists item_type text not null default 'physical',
 add column if not exists variant_id uuid references public.catalog_variants(id) on delete set null,
 add column if not exists selected_options jsonb not null default '{}'::jsonb,
 add column if not exists modifiers_snapshot jsonb not null default '[]'::jsonb,
 add column if not exists sku_snapshot text,
 add column if not exists fulfilment_method text not null default 'delivery';
alter table public.store_orders
 add column if not exists fulfilment_method text not null default 'delivery',
 add column if not exists delivery_zone_name text,
 add column if not exists fulfilment_note text;

-- Cancellation/reopening restores and re-reserves the exact inventory units consumed, including variants and bundle components.
create or replace function public.sync_store_order_stock()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare a record; has_allocations boolean;
begin
 if tg_op='UPDATE' and old.status is distinct from new.status then
  select exists(select 1 from public.store_order_inventory_allocations where store_order_id=new.id) into has_allocations;
  if new.status='Cancelled' and old.status<>'Cancelled' then
   if has_allocations then
    for a in select * from public.store_order_inventory_allocations where store_order_id=new.id loop
     if a.allocation_kind='variant' and a.variant_id is not null then update public.catalog_variants set stock=stock+a.quantity where id=a.variant_id;
     else update public.products set stock=stock+a.quantity where id=a.product_id; end if;
    end loop;
   else
    for a in select product_id,quantity from public.store_order_items where store_order_id=new.id and product_id is not null loop update public.products set stock=stock+a.quantity where id=a.product_id; end loop;
   end if;
  elsif old.status='Cancelled' and new.status<>'Cancelled' then
   if has_allocations then
    for a in select * from public.store_order_inventory_allocations where store_order_id=new.id loop
     if a.allocation_kind='variant' and a.variant_id is not null then update public.catalog_variants set stock=stock-a.quantity where id=a.variant_id and stock>=a.quantity;
     else update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity; end if;
     if not found then raise exception 'Insufficient stock to reopen this cancelled order.'; end if;
    end loop;
   else
    for a in select product_id,quantity from public.store_order_items where store_order_id=new.id and product_id is not null loop update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity; if not found then raise exception 'Insufficient stock to reopen this cancelled order.'; end if; end loop;
   end if;
  end if;
 end if;
 return new;
end $$;

-- Public read-only catalogue projection. Only published products and active options are exposed.
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

-- Option-aware transactional checkout. The legacy place_store_order RPC remains available for older clients.
create or replace function public.place_store_order_catalog(
 p_slug text,p_customer_name text,p_customer_phone text,p_customer_email text,p_delivery_address text,
 p_customer_note text,p_payment_method text,p_items jsonb,p_idempotency_key text,p_delivery_zone_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; z public.store_delivery_zones%rowtype; x jsonb; p public.products%rowtype; v public.catalog_variants%rowtype;
 q numeric; unit numeric(12,2); line numeric(12,2); sub numeric(12,2):=0; fee numeric(12,2):=0; oid uuid; ref text;
 mods jsonb; mod_ids uuid[]; m record; mg record; n integer; existing public.store_orders%rowtype; sku text; itype text;
begin
 if length(trim(coalesce(p_customer_name,'')))<2 then raise exception 'Please provide your full name.'; end if;
 if length(regexp_replace(coalesce(p_customer_phone,''),'\D','','g'))<7 then raise exception 'Please provide a valid phone number.'; end if;
 if length(trim(coalesce(p_delivery_address,'')))<5 then raise exception 'Please provide a delivery address.'; end if;
 if p_payment_method not in ('Bank transfer','Pay on delivery','Paystack') then raise exception 'Invalid payment method.'; end if;
 if p_payment_method='Paystack' and nullif(trim(coalesce(p_customer_email,'')),'') is null then raise exception 'Email address is required for Paystack checkout.'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'Your cart is empty or too large.'; end if;
 if length(trim(coalesce(p_idempotency_key,'')))<16 or length(trim(p_idempotency_key))>120 then raise exception 'Invalid checkout token.'; end if;
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true for update;
 if not found or not ((coalesce(b.plan,'free')='free' and b.trial_ends>now()) or exists(select 1 from public.subscriptions s where s.business_id=b.id and lower(s.status)='active' and s.ends_at>now()) or b.owner_id='327738f9-ad95-4b8e-89c7-6a4847fa1a63') then raise exception 'This shop is in browse-only mode. The owner must upgrade to accept orders.'; end if;
 select * into existing from public.store_orders where business_id=b.id and idempotency_key=trim(p_idempotency_key);
 if found then return jsonb_build_object('order_id',existing.id,'order_ref',existing.order_ref,'subtotal',existing.subtotal,'delivery_fee',existing.delivery_fee,'total',existing.total,'payment_method',existing.payment_method,'receipt_token',existing.receipt_token,'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note); end if;
 fee:=coalesce(b.store_delivery_fee,0);
 if p_delivery_zone_id is not null then
  select * into z from public.store_delivery_zones where id=p_delivery_zone_id and business_id=b.id and is_active for share;
  if not found then raise exception 'The selected delivery zone is unavailable.'; end if;
  fee:=z.fee;
 end if;
 -- Validate every line against merchant-owned catalogue data; client-supplied prices are ignored.
 for x in select value from jsonb_array_elements(p_items) loop
  q:=coalesce((x->>'quantity')::numeric,0); if q<=0 or q>1000 then raise exception 'Invalid item quantity.'; end if;
  select * into p from public.products where id=(x->>'product_id')::uuid and business_id=b.id and store_published for update;
  if not found then raise exception 'A product in your cart is no longer available.'; end if;
  unit:=p.price; sku:=p.sku; itype:=coalesce(p.item_type,'physical');
  if nullif(x->>'variant_id','') is not null then
   select * into v from public.catalog_variants where id=(x->>'variant_id')::uuid and product_id=p.id and business_id=b.id and is_active for update;
   if not found then raise exception 'A selected variation is no longer available.'; end if;
   unit:=coalesce(v.price,p.price); sku:=coalesce(v.sku,p.sku);
   if v.track_inventory and v.stock<q then raise exception 'Not enough stock for variation %.',v.label; end if;
  elsif p.track_inventory and p.stock<q and itype='physical' then raise exception 'Not enough stock for %.',p.name; end if;
  mods:= '[]'::jsonb; mod_ids:=array(select jsonb_array_elements_text(coalesce(x->'modifier_ids','[]'::jsonb))::uuid);
  for mg in select * from public.catalog_modifier_groups where product_id=p.id and business_id=b.id loop
   select count(*) into n from public.catalog_modifiers mm where mm.group_id=mg.id and mm.is_available and mm.id=any(mod_ids);
   if n<mg.min_select or (mg.is_required and n=0) or n>mg.max_select then raise exception 'Please review selections for %.',mg.name; end if;
  end loop;
  for m in select mm.id,mm.name,mm.price,mm.group_id from public.catalog_modifiers mm join public.catalog_modifier_groups gg on gg.id=mm.group_id where gg.product_id=p.id and gg.business_id=b.id and mm.is_available and mm.id=any(mod_ids) loop
   unit:=unit+m.price; mods:=mods||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price));
  end loop;
  sub:=sub+(unit*q);
 end loop;
 ref:='OD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.store_orders(business_id,order_ref,idempotency_key,customer_name,customer_phone,customer_email,delivery_address,customer_note,payment_method,payment_status,subtotal,delivery_fee,total,delivery_zone_name)
 values(b.id,ref,trim(p_idempotency_key),trim(p_customer_name),trim(p_customer_phone),nullif(trim(coalesce(p_customer_email,'')),''),trim(p_delivery_address),nullif(trim(coalesce(p_customer_note,'')),''),p_payment_method,case when p_payment_method in ('Bank transfer','Paystack') then 'Awaiting payment' else 'Pay on delivery' end,sub,fee,sub+fee,z.name) returning id into oid;
 -- Insert immutable line snapshots and reserve inventory in the same transaction.
 for x in select value from jsonb_array_elements(p_items) loop
  q:=(x->>'quantity')::numeric; select * into p from public.products where id=(x->>'product_id')::uuid and business_id=b.id and store_published for update;
  unit:=p.price; sku:=p.sku; mods:='[]'::jsonb; mod_ids:=array(select jsonb_array_elements_text(coalesce(x->'modifier_ids','[]'::jsonb))::uuid);
  if nullif(x->>'variant_id','') is not null then select * into v from public.catalog_variants where id=(x->>'variant_id')::uuid and product_id=p.id and business_id=b.id and is_active for update; unit:=coalesce(v.price,p.price); sku:=coalesce(v.sku,p.sku); if v.track_inventory then update public.catalog_variants set stock=stock-q where id=v.id and stock>=q; if not found then raise exception 'Variation stock changed. Please refresh your cart.'; end if; insert into public.store_order_inventory_allocations(store_order_id,product_id,variant_id,quantity,allocation_kind) values(oid,p.id,v.id,q,'variant'); end if;
  elsif p.track_inventory and coalesce(p.item_type,'physical')='physical' and not coalesce(p.is_bundle,false) then update public.products set stock=stock-q where id=p.id and stock>=q; if not found then raise exception 'Product stock changed. Please refresh your cart.'; end if; insert into public.store_order_inventory_allocations(store_order_id,product_id,quantity,allocation_kind) values(oid,p.id,q,'product'); end if;
  for m in select mm.id,mm.name,mm.price from public.catalog_modifiers mm join public.catalog_modifier_groups gg on gg.id=mm.group_id where gg.product_id=p.id and gg.business_id=b.id and mm.is_available and mm.id=any(mod_ids) loop unit:=unit+m.price; mods:=mods||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price)); end loop;
  if p.is_bundle then
   for m in select bi.component_product_id,bi.quantity* q as qty from public.catalog_bundle_items bi where bi.bundle_product_id=p.id and bi.business_id=b.id loop update public.products set stock=stock-m.qty where id=m.component_product_id and stock>=m.qty; if not found then raise exception 'A bundle component is out of stock.'; end if; insert into public.store_order_inventory_allocations(store_order_id,product_id,quantity,allocation_kind) values(oid,m.component_product_id,m.qty,'bundle_component'); end loop;
  end if;
  insert into public.store_order_items(store_order_id,product_id,product_name,quantity,unit_price,line_total,item_type,variant_id,selected_options,modifiers_snapshot,sku_snapshot,fulfilment_method)
  values(oid,p.id,p.name,q,unit,unit*q,coalesce(p.item_type,'physical'),nullif(x->>'variant_id','')::uuid,coalesce(x->'selected_options','{}'::jsonb),mods,sku,coalesce(x->>'fulfilment_method','delivery'));
 end loop;
 return jsonb_build_object('order_id',oid,'order_ref',ref,'subtotal',sub,'delivery_fee',fee,'total',sub+fee,'payment_method',p_payment_method,'receipt_token',(select receipt_token from public.store_orders where id=oid),'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note);
end $$;
revoke all on function public.place_store_order_catalog(text,text,text,text,text,text,text,jsonb,text,uuid) from public;
grant execute on function public.place_store_order_catalog(text,text,text,text,text,text,text,jsonb,text,uuid) to anon,authenticated;


-- Expired merchants remain browseable; the transactional checkout RPC above enforces access.
create or replace function public.get_public_shop(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
 if not found then return null; end if;
 return jsonb_build_object(
  'business',jsonb_build_object(
   'name',coalesce(b.shop_name,b.name),'description',b.shop_description,'tagline',b.store_tagline,
   'announcement',b.store_announcement,'logo_url',b.logo_url,'phone',b.phone,'address',b.address,
   'currency',coalesce(b.currency,'NGN'),'delivery_fee',b.store_delivery_fee,
   'bank_name',b.store_bank_name,'bank_code',b.store_bank_code,'account_name',b.store_account_name,
   'account_number',b.store_account_number,'bank_verified',coalesce(b.store_account_verified,false),
   'payment_note',b.store_payment_note,'whatsapp',b.store_whatsapp,'support_phone',b.store_support_phone,
   'support_email',b.store_support_email,'support_hours',b.store_support_hours,'instagram',b.store_instagram,
   'delivery_info',b.store_delivery_info,'returns_policy',b.store_returns_policy,'faqs',coalesce(b.store_faqs,'[]'::jsonb),
   'checkout_enabled',((coalesce(b.plan,'free')='free' and b.trial_ends>now()) or exists(select 1 from public.subscriptions s where s.business_id=b.id and lower(s.status)='active' and s.ends_at>now()) or b.owner_id='327738f9-ad95-4b8e-89c7-6a4847fa1a63')
  ),
  'products',coalesce((select jsonb_agg(jsonb_build_object(
   'id',p.id,'name',p.name,'description',p.description,'category',p.category,'price',p.price,
   'compare_at_price',p.compare_at_price,'stock',p.stock,'unit',p.unit,'image_url',p.image_url,
   'available',(p.stock>0 or exists(select 1 from public.catalog_variants v where v.product_id=p.id and v.is_active and (not v.track_inventory or v.stock>0))),'created_at',p.created_at
  ) order by p.name) from public.products p where p.business_id=b.id and p.store_published=true),'[]'::jsonb)
 );
end $$;
revoke all on function public.get_public_shop(text) from public;
grant execute on function public.get_public_shop(text) to anon,authenticated;

commit;
