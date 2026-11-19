-- OrderDesk NG — Storefront Premium + Customer Support upgrade
-- ADDITIVE migration. Run AFTER online_store_upgrade.sql, in your TEST Supabase project first.
-- It does not drop tables, truncate data or delete records.
-- Safe to run more than once.

begin;

-- 1) Merchant-configurable storefront + customer-support details ---------------------------
alter table public.businesses
  add column if not exists store_tagline text,
  add column if not exists store_announcement text,
  add column if not exists store_whatsapp text,
  add column if not exists store_support_phone text,
  add column if not exists store_support_email text,
  add column if not exists store_support_hours text,
  add column if not exists store_instagram text,
  add column if not exists store_delivery_info text,
  add column if not exists store_returns_policy text,
  add column if not exists store_faqs jsonb not null default '[]'::jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='businesses_store_faqs_is_array') then
    alter table public.businesses add constraint businesses_store_faqs_is_array
      check (jsonb_typeof(store_faqs)='array' and jsonb_array_length(store_faqs)<=20);
  end if;
end $$;

grant update(store_tagline,store_announcement,store_whatsapp,store_support_phone,store_support_email,
             store_support_hours,store_instagram,store_delivery_info,store_returns_policy,store_faqs)
  on public.businesses to authenticated;

-- 2) Optional "was" price so the shop can show discount labels (checkout still uses products.price).
alter table public.products
  add column if not exists compare_at_price numeric(12,2);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='products_compare_at_price_nonneg') then
    alter table public.products add constraint products_compare_at_price_nonneg
      check (compare_at_price is null or compare_at_price>=0);
  end if;
end $$;

-- 3) Public shop payload (replaces the previous version; adds support fields + discount price).
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
      'tagline',b.store_tagline,
      'announcement',b.store_announcement,
      'logo_url',b.logo_url,
      'phone',b.phone,
      'address',b.address,
      'currency',coalesce(b.currency,'NGN'),
      'delivery_fee',b.store_delivery_fee,
      'bank_name',b.store_bank_name,
      'account_name',b.store_account_name,
      'account_number',b.store_account_number,
      'payment_note',b.store_payment_note,
      'whatsapp',b.store_whatsapp,
      'support_phone',b.store_support_phone,
      'support_email',b.store_support_email,
      'support_hours',b.store_support_hours,
      'instagram',b.store_instagram,
      'delivery_info',b.store_delivery_info,
      'returns_policy',b.store_returns_policy,
      'faqs',coalesce(b.store_faqs,'[]'::jsonb)
    ),
    'products',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'description',p.description,'category',p.category,
      'price',p.price,'compare_at_price',p.compare_at_price,'stock',p.stock,'unit',p.unit,
      'image_url',p.image_url,'available',(p.stock>0),'created_at',p.created_at
    ) order by p.name) from public.products p where p.business_id=b.id and p.store_published=true),'[]'::jsonb)
  );
end $$;
grant execute on function public.get_public_shop(text) to anon,authenticated;

-- 4) FIX: phone matching. The earlier migration used '\\D' inside a normal string, which Postgres reads as a
--    literal backslash followed by D, so phone numbers were compared without being normalised
--    ("0803 123 4567" would not match "08031234567"). These two functions now strip non-digits properly.
create or replace function public.submit_store_receipt(p_order_ref text,p_phone text,p_receipt_path text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare o public.store_orders%rowtype;
begin
  select * into o from public.store_orders
   where upper(order_ref)=upper(trim(p_order_ref))
     and regexp_replace(customer_phone,'\D','','g')=regexp_replace(coalesce(p_phone,''),'\D','','g') limit 1;
  if not found or o.status='Cancelled' or o.payment_method<>'Bank transfer' or o.payment_status not in ('Awaiting payment','Rejected') then
    raise exception 'This order is not awaiting a transfer receipt.'; end if;
  if p_receipt_path is null or split_part(p_receipt_path,'/',1)<>o.receipt_token::text then raise exception 'Invalid receipt path.'; end if;
  update public.store_orders set receipt_path=p_receipt_path,payment_status='Receipt submitted' where id=o.id;
  return true;
end $$;

create or replace function public.track_store_order(p_order_ref text,p_phone text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'order_ref',so.order_ref,'business_name',coalesce(b.shop_name,b.name),'status',so.status,
    'payment_status',so.payment_status,'payment_method',so.payment_method,'subtotal',so.subtotal,
    'delivery_fee',so.delivery_fee,'total',so.total,'created_at',so.created_at,'updated_at',so.updated_at,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name,'quantity',i.quantity,'line_total',i.line_total)),'[]'::jsonb)
             from public.store_order_items i where i.store_order_id=so.id)
  )
  from public.store_orders so join public.businesses b on b.id=so.business_id
  where upper(so.order_ref)=upper(trim(p_order_ref))
    and regexp_replace(so.customer_phone,'\D','','g')=regexp_replace(coalesce(p_phone,''),'\D','','g')
  limit 1
$$;
grant execute on function public.submit_store_receipt(text,text,text) to anon,authenticated;
grant execute on function public.track_store_order(text,text) to anon,authenticated;

-- 5) Customer enquiries / complaints for each merchant's store -------------------------------
create table if not exists public.store_support_requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_name text not null check (length(trim(customer_name)) between 2 and 120),
  customer_phone text not null check (length(regexp_replace(customer_phone,'\D','','g')) >= 7),
  customer_email text check (customer_email is null or length(customer_email)<=200),
  topic text not null check (topic in ('Order enquiry','Delivery','Payment problem','Missing item','Complaint','Product question','Other')),
  order_ref text check (order_ref is null or length(order_ref)<=40),
  message text not null check (length(trim(message)) between 5 and 2000),
  status text not null default 'New' check (status in ('New','In progress','Resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists store_support_requests_business_idx on public.store_support_requests(business_id,created_at desc);

alter table public.store_support_requests enable row level security;
drop policy if exists store_support_owner_select on public.store_support_requests;
create policy store_support_owner_select on public.store_support_requests for select to authenticated
  using (business_id=public.my_business());
revoke all on public.store_support_requests from anon;
revoke insert,update,delete on public.store_support_requests from authenticated;

create or replace function public.submit_store_support_request(
  p_slug text,p_name text,p_phone text,p_email text,p_topic text,p_order_ref text,p_message text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; r text; recent int;
begin
  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is temporarily unavailable.'; end if;
  if length(trim(coalesce(p_name,'')))<2 then raise exception 'Please enter your name.'; end if;
  if length(regexp_replace(coalesce(p_phone,''),'\D','','g'))<7 then raise exception 'Please enter a valid phone number.'; end if;
  if length(trim(coalesce(p_message,'')))<5 then raise exception 'Please describe your question or problem.'; end if;
  select count(*) into recent from public.store_support_requests
    where business_id=b.id and created_at>now()-interval '1 hour'
      and regexp_replace(customer_phone,'\D','','g')=regexp_replace(p_phone,'\D','','g');
  if recent>=5 then raise exception 'You have sent several messages recently. Please wait a little before sending another.'; end if;
  r:='HLP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.store_support_requests(ref,business_id,customer_name,customer_phone,customer_email,topic,order_ref,message)
  values(r,b.id,trim(p_name),trim(p_phone),nullif(trim(coalesce(p_email,'')),''),
         case when p_topic in ('Order enquiry','Delivery','Payment problem','Missing item','Complaint','Product question','Other') then p_topic else 'Other' end,
         nullif(left(trim(coalesce(p_order_ref,'')),40),''),left(trim(p_message),2000));
  return jsonb_build_object('ref',r);
end $$;
revoke execute on function public.submit_store_support_request(text,text,text,text,text,text,text) from public;
grant execute on function public.submit_store_support_request(text,text,text,text,text,text,text) to anon,authenticated;

create or replace function public.update_store_support_status(p_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if p_status not in ('New','In progress','Resolved') then raise exception 'Invalid status.'; end if;
  update public.store_support_requests set status=p_status,updated_at=now()
   where id=p_id and business_id=public.my_business();
  if not found then raise exception 'Enquiry not found.'; end if;
  return true;
end $$;
revoke execute on function public.update_store_support_status(uuid,text) from public;
grant execute on function public.update_store_support_status(uuid,text) to authenticated;

-- 6) OrderDesk NG PLATFORM support (yours): editable from admin.html, never hard-coded ---------
create table if not exists public.platform_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
revoke all on public.platform_settings from anon,authenticated;

create or replace function public.get_platform_support()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) from public.platform_settings
  where key in ('support_whatsapp','support_email','support_phone','support_hours','help_center_url')
    and nullif(trim(coalesce(value,'')),'') is not null
$$;
revoke execute on function public.get_platform_support() from public;
grant execute on function public.get_platform_support() to anon,authenticated;

create or replace function public.owner_set_platform_support(p_settings jsonb)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare k text;
begin
  if not coalesce(public.owner_is_admin(),false) then raise exception 'Not authorised.'; end if;
  foreach k in array array['support_whatsapp','support_email','support_phone','support_hours','help_center_url'] loop
    if p_settings ? k then
      insert into public.platform_settings(key,value,updated_at) values(k,left(trim(coalesce(p_settings->>k,'')),300),now())
      on conflict (key) do update set value=excluded.value,updated_at=now();
    end if;
  end loop;
  return true;
end $$;
revoke execute on function public.owner_set_platform_support(jsonb) from public;
grant execute on function public.owner_set_platform_support(jsonb) to authenticated;

-- Merchant -> OrderDesk "Report a problem / feedback / account help"
create table if not exists public.platform_support_tickets (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('Problem','Feedback','Account help')),
  subject text not null check (length(trim(subject)) between 3 and 150),
  message text not null check (length(trim(message)) between 5 and 3000),
  status text not null default 'Open' check (status in ('Open','Resolved')),
  created_at timestamptz not null default now()
);
create index if not exists platform_support_tickets_business_idx on public.platform_support_tickets(business_id,created_at desc);
alter table public.platform_support_tickets enable row level security;
drop policy if exists platform_ticket_owner_select on public.platform_support_tickets;
create policy platform_ticket_owner_select on public.platform_support_tickets for select to authenticated
  using (business_id=public.my_business());
revoke all on public.platform_support_tickets from anon;
revoke insert,update,delete on public.platform_support_tickets from authenticated;

create or replace function public.submit_platform_ticket(p_kind text,p_subject text,p_message text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare bid uuid; r text; recent int;
begin
  bid:=public.my_business();
  if bid is null then raise exception 'Please sign in first.'; end if;
  if p_kind not in ('Problem','Feedback','Account help') then raise exception 'Invalid request type.'; end if;
  if length(trim(coalesce(p_subject,'')))<3 then raise exception 'Please add a short subject.'; end if;
  if length(trim(coalesce(p_message,'')))<5 then raise exception 'Please describe the issue.'; end if;
  select count(*) into recent from public.platform_support_tickets where business_id=bid and created_at>now()-interval '1 hour';
  if recent>=10 then raise exception 'Too many requests. Please try again later.'; end if;
  r:='TKT-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into public.platform_support_tickets(ref,business_id,kind,subject,message)
  values(r,bid,p_kind,left(trim(p_subject),150),left(trim(p_message),3000));
  return jsonb_build_object('ref',r);
end $$;
revoke execute on function public.submit_platform_ticket(text,text,text) from public;
grant execute on function public.submit_platform_ticket(text,text,text) to authenticated;

create or replace function public.owner_list_platform_tickets()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not coalesce(public.owner_is_admin(),false) then raise exception 'Not authorised.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,'ref',t.ref,'kind',t.kind,'subject',t.subject,'message',t.message,'status',t.status,'created_at',t.created_at,
      'business_name',b.name,'business_email',b.email,'business_phone',b.phone) order by t.created_at desc)
    from public.platform_support_tickets t join public.businesses b on b.id=t.business_id),'[]'::jsonb);
end $$;
revoke execute on function public.owner_list_platform_tickets() from public;
grant execute on function public.owner_list_platform_tickets() to authenticated;

create or replace function public.owner_resolve_platform_ticket(p_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not coalesce(public.owner_is_admin(),false) then raise exception 'Not authorised.'; end if;
  if p_status not in ('Open','Resolved') then raise exception 'Invalid status.'; end if;
  update public.platform_support_tickets set status=p_status where id=p_id;
  return found;
end $$;
revoke execute on function public.owner_resolve_platform_ticket(uuid,text) from public;
grant execute on function public.owner_resolve_platform_ticket(uuid,text) to authenticated;

commit;
