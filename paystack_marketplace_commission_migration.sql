-- OrderDesk NG: Paystack checkout + 5% marketplace commission.
-- Run AFTER online_store_upgrade.sql and online_store_support_upgrade.sql.
-- Additive migration: existing orders, products, customers and subscriptions are preserved.
begin;

-- Paystack subaccount identity is stored per merchant business. Bank details are re-verified
-- server-side before a subaccount is created or used.
alter table public.businesses
  add column if not exists store_bank_code text,
  add column if not exists store_account_verified boolean not null default false,
  add column if not exists store_account_verified_at timestamptz,
  add column if not exists paystack_subaccount_code text,
  add column if not exists paystack_subaccount_bank_code_snapshot text,
  add column if not exists paystack_subaccount_account_snapshot text,
  add column if not exists paystack_subaccount_commission_snapshot numeric(5,2);

alter table public.store_orders
  add column if not exists paystack_reference text,
  add column if not exists paystack_authorization_url text,
  add column if not exists paystack_subaccount_code text,
  add column if not exists platform_commission_rate numeric(5,2),
  add column if not exists platform_commission_amount numeric(12,2),
  add column if not exists paystack_paid_at timestamptz;

-- Include Paystack as a payment method without changing existing methods.
alter table public.store_orders drop constraint if exists store_orders_payment_method_check;
alter table public.store_orders add constraint store_orders_payment_method_check
  check (payment_method in ('Bank transfer','Pay on delivery','Paystack'));

create unique index if not exists store_orders_paystack_reference_unique
  on public.store_orders(paystack_reference) where paystack_reference is not null;

-- Server-managed platform commission setting. Only service-role code can read or change it.
create table if not exists public.platform_payment_settings (
  id smallint primary key check (id=1),
  commission_percent numeric(5,2) not null default 5.00 check (commission_percent>=0 and commission_percent<=30),
  updated_at timestamptz not null default now()
);
insert into public.platform_payment_settings(id,commission_percent)
values(1,5.00) on conflict(id) do nothing;
alter table public.platform_payment_settings enable row level security;
revoke all on public.platform_payment_settings from anon,authenticated;

-- Ledger for platform commission. Paystack rows are already collected through the split;
-- bank-transfer and pay-on-delivery rows are recorded as amounts due from the merchant.
create table if not exists public.platform_commissions (
  id uuid primary key default gen_random_uuid(),
  store_order_id uuid not null unique references public.store_orders(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  commission_rate numeric(5,2) not null,
  commission_base numeric(12,2) not null,
  commission_amount numeric(12,2) not null,
  collection_method text not null check(collection_method in ('Paystack split','Manual transfer','Pay on delivery')),
  collection_status text not null check(collection_status in ('Collected','Due')),
  paystack_reference text,
  created_at timestamptz not null default now()
);
create index if not exists platform_commissions_business_created_idx
  on public.platform_commissions(business_id,created_at desc);
alter table public.platform_commissions enable row level security;
revoke all on public.platform_commissions from anon,authenticated;

-- Extend the existing atomic checkout RPC to accept Paystack.
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
  if p_payment_method not in ('Bank transfer','Pay on delivery','Paystack') then raise exception 'Invalid payment method.'; end if;
  if p_payment_method='Paystack' and nullif(trim(coalesce(p_customer_email,'')),'') is null then raise exception 'Email address is required for Paystack checkout.'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'Your cart is empty or too large.'; end if;
  if length(trim(coalesce(p_idempotency_key,'')))<16 or length(trim(p_idempotency_key))>120 then raise exception 'Invalid checkout token.'; end if;

  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true for update;
  if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is temporarily unavailable.'; end if;
  select * into existing from public.store_orders where business_id=b.id and idempotency_key=trim(p_idempotency_key);
  if found then
    return jsonb_build_object('order_id',existing.id,'order_ref',existing.order_ref,'subtotal',existing.subtotal,'delivery_fee',existing.delivery_fee,'total',existing.total,'payment_method',existing.payment_method,'receipt_token',existing.receipt_token,'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note,'paystack_reference',existing.paystack_reference,'paystack_authorization_url',existing.paystack_authorization_url);
  end if;
  fee:=coalesce(b.store_delivery_fee,0);
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
    values(b.id,ref,trim(p_idempotency_key),trim(p_customer_name),trim(p_customer_phone),nullif(trim(coalesce(p_customer_email,'')),''),trim(p_delivery_address),nullif(trim(coalesce(p_customer_note,'')),''),p_payment_method,case when p_payment_method in ('Bank transfer','Paystack') then 'Awaiting payment' else 'Pay on delivery' end,subtotal,fee,subtotal+fee)
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
  return jsonb_build_object('order_id',oid,'order_ref',ref,'subtotal',subtotal,'delivery_fee',fee,'total',subtotal+fee,'payment_method',p_payment_method,'receipt_token',(select receipt_token from public.store_orders where id=oid),'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note);
end $$;

-- Public shop payload includes the selected bank code so the browser can offer Paystack only
-- when the merchant has supplied the required bank details. Secret credentials never leave Netlify.
create or replace function public.get_public_shop(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then return null; end if;
  return jsonb_build_object(
    'business',jsonb_build_object(
      'name',coalesce(b.shop_name,b.name),'description',b.shop_description,'tagline',b.store_tagline,
      'announcement',b.store_announcement,'logo_url',b.logo_url,'phone',b.phone,'address',b.address,
      'currency',coalesce(b.currency,'NGN'),'delivery_fee',b.store_delivery_fee,
      'bank_name',b.store_bank_name,'bank_code',b.store_bank_code,'account_name',b.store_account_name,
      'account_number',b.store_account_number,'bank_verified',coalesce(b.store_account_verified,false),
      'payment_note',b.store_payment_note,'whatsapp',b.store_whatsapp,'support_phone',b.store_support_phone,
      'support_email',b.store_support_email,'support_hours',b.store_support_hours,'instagram',b.store_instagram,
      'delivery_info',b.store_delivery_info,'returns_policy',b.store_returns_policy,'faqs',coalesce(b.store_faqs,'[]'::jsonb)
    ),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'description',p.description,'category',p.category,'price',p.price,
      'compare_at_price',p.compare_at_price,'stock',p.stock,'unit',p.unit,'image_url',p.image_url,
      'available',(p.stock>0),'created_at',p.created_at
    ) order by p.name) from public.products p where p.business_id=b.id and p.store_published=true),'[]'::jsonb)
  );
end $$;

-- Commission ledger for manual payment routes. These amounts are due from the seller; they are
-- not silently deducted from a direct bank transfer or cash collected by the seller.
create or replace function public.record_manual_store_commission()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare rate numeric(5,2);
begin
  if new.payment_method='Bank transfer' and new.payment_status='Confirmed'
     and old.payment_status is distinct from new.payment_status then
    select commission_percent into rate from public.platform_payment_settings where id=1;
    insert into public.platform_commissions(store_order_id,business_id,commission_rate,commission_base,commission_amount,collection_method,collection_status)
    values(new.id,new.business_id,coalesce(rate,5),new.subtotal,round(new.subtotal*coalesce(rate,5)/100,2),'Manual transfer','Due')
    on conflict(store_order_id) do nothing;
  elsif new.payment_method='Pay on delivery' and new.status='Delivered'
     and old.status is distinct from new.status then
    select commission_percent into rate from public.platform_payment_settings where id=1;
    insert into public.platform_commissions(store_order_id,business_id,commission_rate,commission_base,commission_amount,collection_method,collection_status)
    values(new.id,new.business_id,coalesce(rate,5),new.subtotal,round(new.subtotal*coalesce(rate,5)/100,2),'Pay on delivery','Due')
    on conflict(store_order_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists store_order_manual_commission on public.store_orders;
create trigger store_order_manual_commission after update of payment_status,status on public.store_orders
for each row execute function public.record_manual_store_commission();

-- Do not grant direct access to the commission ledger or platform settings.
revoke all on public.platform_commissions from public,anon,authenticated;
revoke all on public.platform_payment_settings from public,anon,authenticated;
revoke execute on function public.record_manual_store_commission() from public,anon,authenticated;
revoke execute on function public.place_store_order(text,text,text,text,text,text,text,jsonb,text) from public;
grant execute on function public.place_store_order(text,text,text,text,text,text,text,jsonb,text) to anon,authenticated;
revoke execute on function public.get_public_shop(text) from public;
grant execute on function public.get_public_shop(text) to anon,authenticated;

commit;
