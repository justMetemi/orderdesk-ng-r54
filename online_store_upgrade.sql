-- OrderDesk NG Online Store
-- ADDITIVE migration. Run only in a separate TEST Supabase project first.
-- Prerequisites: schema.sql, schema2.sql, and the existing subscription setup.
-- This script does not drop or rewrite existing OrderDesk tables/records.

begin;

-- 1) Business storefront settings.
alter table public.businesses
  add column if not exists shop_name text,
  add column if not exists shop_description text,
  add column if not exists shop_slug text,
  add column if not exists store_enabled boolean not null default false,
  add column if not exists store_delivery_fee numeric(12,2) not null default 0 check (store_delivery_fee >= 0),
  add column if not exists store_bank_name text,
  add column if not exists store_bank_code text,
  add column if not exists store_account_name text,
  add column if not exists store_account_number text,
  add column if not exists store_payment_note text;

-- A slug is optional until the owner configures the store, but when present it must be URL-safe.
do $$ begin
  if not exists (select 1 from pg_constraint where conname='businesses_shop_slug_format') then
    alter table public.businesses add constraint businesses_shop_slug_format
      check (shop_slug is null or shop_slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$');
  end if;
end $$;

create unique index if not exists businesses_shop_slug_unique
  on public.businesses (lower(shop_slug)) where shop_slug is not null;

-- schema2.sql revoked broad business updates, so explicitly allow only owner-editable store fields.
grant update(shop_name,shop_description,shop_slug,store_enabled,store_delivery_fee,store_bank_name,store_bank_code,store_account_name,store_account_number,store_payment_note) on public.businesses to authenticated;

-- 2) Reuse the existing Products table.
alter table public.products
  add column if not exists unit text not null default 'Pieces',
  add column if not exists store_published boolean not null default false;

grant select,insert,update,delete on public.products to authenticated;

-- 3) Public-store orders. These are intentionally separate from manual orders so existing records/logic remain untouched.
create table if not exists public.store_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  order_ref text not null unique,
  idempotency_key text,
  customer_name text not null check (length(trim(customer_name)) between 2 and 120),
  customer_phone text not null check (length(regexp_replace(customer_phone,'\\D','','g')) >= 7),
  customer_email text,
  delivery_address text not null check (length(trim(delivery_address)) >= 5),
  customer_note text,
  payment_method text not null check (payment_method in ('Bank transfer','Pay on delivery')),
  payment_status text not null default 'Awaiting payment' check (payment_status in ('Awaiting payment','Receipt submitted','Confirmed','Pay on delivery','Rejected')),
  receipt_path text,
  receipt_token uuid not null default gen_random_uuid(),
  subtotal numeric(12,2) not null check (subtotal >= 0),
  delivery_fee numeric(12,2) not null default 0 check (delivery_fee >= 0),
  total numeric(12,2) not null check (total >= 0),
  status text not null default 'Pending' check (status in ('Pending','Confirmed','Processing','Ready for Delivery','Delivered','Cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists store_orders_business_idempotency_unique
  on public.store_orders(business_id,idempotency_key) where idempotency_key is not null;
create index if not exists store_orders_business_created_idx on public.store_orders(business_id,created_at desc);
create index if not exists store_orders_business_status_idx on public.store_orders(business_id,status);

create table if not exists public.store_order_items (
  id uuid primary key default gen_random_uuid(),
  store_order_id uuid not null references public.store_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity numeric not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) not null check (line_total >= 0)
);
create index if not exists store_order_items_order_idx on public.store_order_items(store_order_id);

-- 4) Keep updated_at current.
create or replace function public.touch_store_order_updated_at()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin new.updated_at:=now(); return new; end $$;
drop trigger if exists store_orders_touch_updated_at on public.store_orders;
create trigger store_orders_touch_updated_at before update on public.store_orders for each row execute function public.touch_store_order_updated_at();

-- 5) Atomic stock reservation for public-store orders.
-- Checkout deducts stock immediately. Cancellation restores it; moving a cancelled order back to an active state reserves it again.
create or replace function public.sync_store_order_stock()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare i record;
begin
  if tg_op='INSERT' then
    if new.status<>'Cancelled' then
      for i in select product_id,quantity from public.store_order_items where store_order_id=new.id and product_id is not null loop
        update public.products set stock=stock-i.quantity where id=i.product_id and stock>=i.quantity;
        if not found then raise exception 'Insufficient stock while creating order.'; end if;
      end loop;
    end if;
  elsif tg_op='UPDATE' and old.status is distinct from new.status then
    if old.status<>'Cancelled' and new.status='Cancelled' then
      for i in select product_id,quantity from public.store_order_items where store_order_id=new.id and product_id is not null loop
        update public.products set stock=stock+i.quantity where id=i.product_id;
      end loop;
    elsif old.status='Cancelled' and new.status<>'Cancelled' then
      for i in select product_id,quantity from public.store_order_items where store_order_id=new.id and product_id is not null loop
        update public.products set stock=stock-i.quantity where id=i.product_id and stock>=i.quantity;
        if not found then raise exception 'Insufficient stock to reopen this cancelled order.'; end if;
      end loop;
    end if;
  end if;
  return new;
end $$;

-- Do not attach this trigger to store_order_items: checkout performs the stock reservation after all lines are created in one transaction.
-- Status changes use the trigger below after item rows already exist.
drop trigger if exists store_orders_stock_status on public.store_orders;
create trigger store_orders_stock_status after update of status on public.store_orders for each row execute function public.sync_store_order_stock();

-- 6) Owner RLS. Public customers never receive direct table SELECT.
alter table public.store_orders enable row level security;
alter table public.store_order_items enable row level security;

drop policy if exists store_orders_owner_all on public.store_orders;
drop policy if exists store_order_items_owner_all on public.store_order_items;
create policy store_orders_owner_select on public.store_orders for select to authenticated
  using (business_id=public.my_business());
create policy store_order_items_owner_select on public.store_order_items for select to authenticated
  using (exists(select 1 from public.store_orders so where so.id=store_order_id and so.business_id=public.my_business()));

-- 7) Subscription/trial access helper for public storefront RPCs.
create or replace function public.has_orderdesk_access_for_business(p_business_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.businesses b
    where b.id=p_business_id
      and ((coalesce(b.plan,'free')='free' and b.trial_ends is not null and b.trial_ends>now())
        or exists(select 1 from public.subscriptions s where s.business_id=b.id and lower(coalesce(s.status,''))='active' and s.ends_at>now()))
  )
$$;

-- 8) Narrow public shop data RPC. No table-wide anonymous SELECT is granted.
create or replace function public.get_public_shop(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
  select * into b from public.businesses
  where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then return null; end if;
  return jsonb_build_object(
    'business',jsonb_build_object(
      'name',coalesce(b.shop_name,b.name),
      'description',b.shop_description,
      'logo_url',b.logo_url,
      'phone',b.phone,
      'address',b.address,
      'currency',coalesce(b.currency,'NGN'),
      'delivery_fee',b.store_delivery_fee,
      'bank_name',b.store_bank_name,
      'account_name',b.store_account_name,
      'account_number',b.store_account_number,
      'payment_note',b.store_payment_note
    ),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'description',p.description,'category',p.category,
      'price',p.price,'stock',p.stock,'unit',p.unit,'image_url',p.image_url,
      'available',(p.stock>0)
    ) order by p.name) from public.products p where p.business_id=b.id and p.store_published=true),'[]'::jsonb)
  );
end $$;

-- 9) Atomic checkout. Browser prices, totals, business IDs and stock values are ignored.
create or replace function public.place_store_order(
  p_slug text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_delivery_address text,
  p_customer_note text,
  p_payment_method text,
  p_items jsonb,
  p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.businesses%rowtype;
  x record;
  p public.products%rowtype;
  q numeric;
  subtotal numeric(12,2):=0;
  fee numeric(12,2):=0;
  oid uuid;
  ref text;
  line numeric(12,2);
  existing public.store_orders%rowtype;
begin
  if length(trim(coalesce(p_customer_name,'')))<2 then raise exception 'Please provide your full name.'; end if;
  if length(regexp_replace(coalesce(p_customer_phone,''),'\\D','','g'))<7 then raise exception 'Please provide a valid phone number.'; end if;
  if length(trim(coalesce(p_delivery_address,'')))<5 then raise exception 'Please provide a delivery address.'; end if;
  if p_payment_method not in ('Bank transfer','Pay on delivery') then raise exception 'Invalid payment method.'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'Your cart is empty or too large.'; end if;
  if length(trim(coalesce(p_idempotency_key,'')))<16 or length(trim(p_idempotency_key))>120 then raise exception 'Invalid checkout token.'; end if;

  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true for update;
  if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is temporarily unavailable.'; end if;

  select * into existing from public.store_orders where business_id=b.id and idempotency_key=trim(p_idempotency_key);
  if found then
    return jsonb_build_object('order_id',existing.id,'order_ref',existing.order_ref,'subtotal',existing.subtotal,'delivery_fee',existing.delivery_fee,'total',existing.total,'payment_method',existing.payment_method,'receipt_token',existing.receipt_token,'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note);
  end if;

  fee:=coalesce(b.store_delivery_fee,0);

  -- Merge duplicate cart lines and lock each product before using its database price/stock.
  for x in select product_id,sum(quantity) as quantity from jsonb_to_recordset(p_items) as z(product_id uuid,quantity numeric) group by product_id loop
    q:=x.quantity;
    if x.product_id is null or q<=0 or q>10000 then raise exception 'Invalid item quantity.'; end if;
    select * into p from public.products where id=x.product_id and business_id=b.id and store_published=true for update;
    if not found then raise exception 'A product in your cart is no longer available.'; end if;
    if p.stock<q then raise exception 'Not enough stock for %.',p.name; end if;
    subtotal:=subtotal+(p.price*q);
  end loop;

  ref:='OD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  insert into public.store_orders(business_id,order_ref,idempotency_key,customer_name,customer_phone,customer_email,delivery_address,customer_note,payment_method,payment_status,subtotal,delivery_fee,total)
    values(b.id,ref,trim(p_idempotency_key),trim(p_customer_name),trim(p_customer_phone),nullif(trim(coalesce(p_customer_email,'')),''),trim(p_delivery_address),nullif(trim(coalesce(p_customer_note,'')),''),p_payment_method,case when p_payment_method='Bank transfer' then 'Awaiting payment' else 'Pay on delivery' end,subtotal,fee,subtotal+fee)
    returning id into oid;

  for x in select product_id,sum(quantity) as quantity from jsonb_to_recordset(p_items) as z(product_id uuid,quantity numeric) group by product_id loop
    q:=x.quantity;
    select * into p from public.products where id=x.product_id and business_id=b.id and store_published=true for update;
    line:=p.price*q;
    insert into public.store_order_items(store_order_id,product_id,product_name,quantity,unit_price,line_total)
      values(oid,p.id,p.name,q,p.price,line);
    update public.products set stock=stock-q where id=p.id and stock>=q;
    if not found then raise exception 'Not enough stock for %.',p.name; end if;
  end loop;

  return jsonb_build_object('order_id',oid,'order_ref',ref,'subtotal',subtotal,'delivery_fee',fee,'total',subtotal+fee,'payment_method',p_payment_method,'receipt_token', (select receipt_token from public.store_orders where id=oid),'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note);
end $$;

-- 10) Customer receipt submission. The phone + reference must match; path must belong to that order.
create or replace function public.submit_store_receipt(p_order_ref text,p_phone text,p_receipt_path text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare o public.store_orders%rowtype;
begin
  select * into o from public.store_orders where upper(order_ref)=upper(trim(p_order_ref)) and regexp_replace(customer_phone,'\\D','','g')=regexp_replace(coalesce(p_phone,''),'\\D','','g') limit 1;
  if not found or o.status='Cancelled' or o.payment_method<>'Bank transfer' or o.payment_status not in ('Awaiting payment','Rejected') then raise exception 'This order is not awaiting a transfer receipt.'; end if;
  if p_receipt_path is null or split_part(p_receipt_path,'/',1)<>o.receipt_token::text then raise exception 'Invalid receipt path.'; end if;
  update public.store_orders set receipt_path=p_receipt_path,payment_status='Receipt submitted' where id=o.id;
  return true;
end $$;

-- 11) Public tracking: reference + phone, and no customer address/receipt path is exposed.
create or replace function public.track_store_order(p_order_ref text,p_phone text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'order_ref',so.order_ref,'business_name',coalesce(b.shop_name,b.name),'status',so.status,
    'payment_status',so.payment_status,'payment_method',so.payment_method,'subtotal',so.subtotal,
    'delivery_fee',so.delivery_fee,'total',so.total,'created_at',so.created_at,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name,'quantity',i.quantity,'line_total',i.line_total)),'[]'::jsonb) from public.store_order_items i where i.store_order_id=so.id)
  )
  from public.store_orders so join public.businesses b on b.id=so.business_id
  where upper(so.order_ref)=upper(trim(p_order_ref))
    and regexp_replace(so.customer_phone,'\\D','','g')=regexp_replace(coalesce(p_phone,''),'\\D','','g')
  limit 1
$$;

-- 12) Owner-only payment review and order-status functions.
create or replace function public.review_store_payment(p_order_id uuid,p_decision text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare o public.store_orders%rowtype;
begin
  select * into o from public.store_orders where id=p_order_id and business_id=public.my_business() for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.payment_method<>'Bank transfer' or o.payment_status<>'Receipt submitted' then raise exception 'This order has no receipt awaiting review.'; end if;
  if p_decision='confirm' then update public.store_orders set payment_status='Confirmed' where id=o.id;
  elsif p_decision='reject' then update public.store_orders set payment_status='Rejected',receipt_path=null where id=o.id;
  else raise exception 'Invalid payment decision.'; end if;
  return true;
end $$;

create or replace function public.update_store_order_status(p_order_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare o public.store_orders%rowtype;
begin
  if p_status not in ('Pending','Confirmed','Processing','Ready for Delivery','Delivered','Cancelled') then raise exception 'Invalid order status.'; end if;
  select * into o from public.store_orders where id=p_order_id and business_id=public.my_business() for update;
  if not found then raise exception 'Order not found.'; end if;
  update public.store_orders set status=p_status where id=o.id;
  return true;
end $$;

-- 13) Private receipt storage. A narrow SECURITY DEFINER predicate avoids exposing order rows to anonymous users.
create or replace function public.can_upload_store_receipt(p_token text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.store_orders so
    where so.receipt_token::text=p_token
      and so.status<>'Cancelled'
      and so.payment_method='Bank transfer'
      and so.payment_status in ('Awaiting payment','Rejected')
  )
$$;
revoke all on function public.can_upload_store_receipt(text) from public;
grant execute on function public.can_upload_store_receipt(text) to anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('store-receipts','store-receipts',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'];

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='store_receipt_customer_upload') then
    create policy store_receipt_customer_upload on storage.objects for insert to anon,authenticated
      with check (
        bucket_id='store-receipts'
        and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
        and public.can_upload_store_receipt((storage.foldername(name))[1])
      );
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='store_receipt_owner_read') then
    create policy store_receipt_owner_read on storage.objects for select to authenticated
      using (bucket_id='store-receipts' and exists(select 1 from public.store_orders so where so.receipt_token::text=(storage.foldername(name))[1] and so.business_id=public.my_business()));
  end if;
end $$;

-- No direct anonymous table access. Only the explicitly granted RPCs are public.
revoke all on public.store_orders from anon;
revoke all on public.store_order_items from anon;
revoke execute on function public.get_public_shop(text) from public;
revoke execute on function public.place_store_order(text,text,text,text,text,text,text,jsonb,text) from public;
revoke execute on function public.submit_store_receipt(text,text,text) from public;
revoke execute on function public.track_store_order(text,text) from public;
revoke execute on function public.has_orderdesk_access_for_business(uuid) from public;
revoke execute on function public.review_store_payment(uuid,text) from public;
revoke execute on function public.update_store_order_status(uuid,text) from public;
grant execute on function public.get_public_shop(text) to anon,authenticated;
grant execute on function public.place_store_order(text,text,text,text,text,text,text,jsonb,text) to anon,authenticated;
grant execute on function public.submit_store_receipt(text,text,text) to anon,authenticated;
grant execute on function public.track_store_order(text,text) to anon,authenticated;
grant execute on function public.review_store_payment(uuid,text) to authenticated;
grant execute on function public.update_store_order_status(uuid,text) to authenticated;

commit;
