-- OrderDesk NG R5.0 Customer Experience Upgrade
-- ADDITIVE migration. Run only in the OrderDesk NG Supabase project.
-- Test in a separate Supabase project first. Does not drop existing business/order data.
begin;

-- 1) One universal customer identity shared across all OrderDesk stores.
create table if not exists public.store_customer_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  email text,
  default_address text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.store_customer_profiles enable row level security;
drop policy if exists store_customer_profile_self on public.store_customer_profiles;
create policy store_customer_profile_self on public.store_customer_profiles
  for all to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
grant select,insert,update on public.store_customer_profiles to authenticated;

alter table public.store_orders add column if not exists customer_user_id uuid references auth.users(id) on delete set null;
create index if not exists store_orders_customer_user_idx on public.store_orders(customer_user_id,created_at desc);
create or replace function public.attach_store_customer_identity()
returns trigger language plpgsql security invoker set search_path=public,pg_temp as $$
begin
  if auth.uid() is not null then new.customer_user_id:=auth.uid(); end if;
  return new;
end $$;
drop trigger if exists store_orders_attach_customer_identity on public.store_orders;
create trigger store_orders_attach_customer_identity before insert on public.store_orders
  for each row execute function public.attach_store_customer_identity();

create table if not exists public.store_customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null default 'Home',
  recipient_name text not null,
  phone text not null,
  address text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.store_customer_addresses enable row level security;
drop policy if exists store_customer_addresses_self on public.store_customer_addresses;
create policy store_customer_addresses_self on public.store_customer_addresses
  for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select,insert,update,delete on public.store_customer_addresses to authenticated;

create table if not exists public.store_customer_wishlist (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id,product_id)
);
alter table public.store_customer_wishlist enable row level security;
drop policy if exists store_customer_wishlist_self on public.store_customer_wishlist;
create policy store_customer_wishlist_self on public.store_customer_wishlist
  for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select,delete on public.store_customer_wishlist to authenticated;
create or replace function public.save_public_store_wishlist(p_slug text,p_product_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in to save products to your wishlist.'; end if;
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
 if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is unavailable.'; end if;
 if not exists(select 1 from public.products where id=p_product_id and business_id=b.id and store_published=true) then raise exception 'This product is no longer available.'; end if;
 insert into public.store_customer_wishlist(user_id,product_id,business_id) values(auth.uid(),p_product_id,b.id) on conflict(user_id,product_id) do nothing;
 return true;
end $$;
revoke all on function public.save_public_store_wishlist(text,uuid) from public;
grant execute on function public.save_public_store_wishlist(text,uuid) to authenticated;

create or replace function public.save_my_store_customer_profile(p_full_name text,p_phone text,p_email text,p_default_address text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare result public.store_customer_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in to save your customer profile.'; end if;
  if char_length(trim(coalesce(p_full_name,''))) not between 2 and 120 then raise exception 'Enter your full name.'; end if;
  insert into public.store_customer_profiles(user_id,full_name,phone,email,default_address,updated_at)
  values(auth.uid(),trim(p_full_name),nullif(trim(p_phone),''),lower(nullif(trim(p_email),'')),nullif(trim(p_default_address),''),now())
  on conflict(user_id) do update set full_name=excluded.full_name,phone=excluded.phone,email=excluded.email,default_address=excluded.default_address,updated_at=now()
  returning * into result;
  return to_jsonb(result);
end $$;

create or replace function public.get_my_store_customer_data()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare prof jsonb; ord jsonb; wish jsonb; addr jsonb;
begin
  if auth.uid() is null then raise exception 'Sign in to view your customer account.'; end if;
  select to_jsonb(p) into prof from public.store_customer_profiles p where p.user_id=auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object('order_ref',so.order_ref,'shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'status',so.status,'payment_status',so.payment_status,'total',so.total,'created_at',so.created_at,'delivery_address',so.delivery_address) order by so.created_at desc),'[]'::jsonb)
    into ord from public.store_orders so join public.businesses b on b.id=so.business_id where so.customer_user_id=auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object('product_id',w.product_id,'business_id',w.business_id,'product_name',p.name,'shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'price',p.price,'image_url',p.image_url) order by w.created_at desc),'[]'::jsonb)
    into wish from public.store_customer_wishlist w join public.products p on p.id=w.product_id join public.businesses b on b.id=w.business_id where w.user_id=auth.uid() and p.store_published=true;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.is_default desc,a.created_at desc),'[]'::jsonb) into addr from public.store_customer_addresses a where a.user_id=auth.uid();
  return jsonb_build_object('profile',coalesce(prof,'{}'::jsonb),'orders',coalesce(ord,'[]'::jsonb),'wishlist',coalesce(wish,'[]'::jsonb),'addresses',coalesce(addr,'[]'::jsonb));
end $$;
revoke all on function public.save_my_store_customer_profile(text,text,text,text) from public;
revoke all on function public.get_my_store_customer_data() from public;
grant execute on function public.save_my_store_customer_profile(text,text,text,text) to authenticated;
grant execute on function public.get_my_store_customer_data() to authenticated;

create or replace function public.add_my_store_customer_address(p_label text,p_recipient_name text,p_phone text,p_address text,p_is_default boolean default false)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare aid uuid;
begin
 if auth.uid() is null then raise exception 'Sign in to save an address.'; end if;
 if char_length(trim(coalesce(p_recipient_name,'')))<2 or char_length(trim(coalesce(p_phone,'')))<7 or char_length(trim(coalesce(p_address,'')))<5 then raise exception 'Complete the recipient, phone and delivery address.'; end if;
 if p_is_default then update public.store_customer_addresses set is_default=false where user_id=auth.uid(); end if;
 insert into public.store_customer_addresses(user_id,label,recipient_name,phone,address,is_default)
 values(auth.uid(),left(trim(coalesce(p_label,'Address')),40),trim(p_recipient_name),trim(p_phone),trim(p_address),p_is_default) returning id into aid;
 return aid;
end $$;
create or replace function public.delete_my_store_customer_address(p_address_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin delete from public.store_customer_addresses where id=p_address_id and user_id=auth.uid(); return found; end $$;
revoke all on function public.add_my_store_customer_address(text,text,text,text,boolean) from public;
revoke all on function public.delete_my_store_customer_address(uuid) from public;
grant execute on function public.add_my_store_customer_address(text,text,text,text,boolean) to authenticated;
grant execute on function public.delete_my_store_customer_address(uuid) to authenticated;

-- 2) Product reviews: moderation, merchant replies and verified-purchase flags.
alter table public.store_product_reviews add column if not exists review_status text not null default 'approved' check(review_status in('pending','approved','hidden'));
alter table public.store_product_reviews add column if not exists merchant_reply text;
alter table public.store_product_reviews add column if not exists replied_at timestamptz;
alter table public.store_product_reviews add column if not exists verified_purchase boolean not null default false;
alter table public.store_product_reviews add column if not exists customer_user_id uuid references auth.users(id) on delete set null;
create index if not exists store_product_reviews_business_status_idx on public.store_product_reviews(business_id,review_status,created_at desc);
create or replace function public.get_public_shop_reviews(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; result jsonb;
begin
  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id',x.product_id,'average',round(x.avg_rating::numeric,1),'count',x.review_count,'reviews',x.reviews)), '[]'::jsonb)
  into result from (
    select r.product_id,avg(r.rating)::numeric avg_rating,count(*)::int review_count,
      (select coalesce(jsonb_agg(jsonb_build_object('name',z.reviewer_name,'rating',z.rating,'comment',z.comment,'created_at',z.created_at,'verified_purchase',z.verified_purchase,'merchant_reply',z.merchant_reply) order by z.created_at desc),'[]'::jsonb)
       from (select reviewer_name,rating,comment,created_at,verified_purchase,merchant_reply from public.store_product_reviews where product_id=r.product_id and review_status='approved' order by created_at desc limit 10) z) reviews
    from public.store_product_reviews r join public.products p on p.id=r.product_id and p.business_id=b.id and p.store_published=true
    where r.business_id=b.id and r.review_status='approved' group by r.product_id
  ) x;
  return result;
end $$;
create or replace function public.submit_public_product_review(p_slug text,p_product_id uuid,p_reviewer_name text,p_reviewer_email text,p_rating integer,p_comment text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; verified boolean:=false;
begin
  select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is unavailable.'; end if;
  if not exists(select 1 from public.products where id=p_product_id and business_id=b.id and store_published=true) then raise exception 'This product is not available for reviews.'; end if;
  if char_length(trim(coalesce(p_reviewer_name,''))) not between 2 and 60 then raise exception 'Enter your name (2–60 characters).'; end if;
  if char_length(trim(coalesce(p_reviewer_email,''))) not between 5 and 254 or trim(p_reviewer_email) !~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then raise exception 'Enter a valid email address.'; end if;
  if p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5.'; end if;
  if char_length(trim(coalesce(p_comment,''))) not between 5 and 1000 then raise exception 'Feedback must be 5–1,000 characters.'; end if;
  select exists(select 1 from public.store_orders so join public.store_order_items si on si.store_order_id=so.id where so.business_id=b.id and si.product_id=p_product_id and so.status='Delivered' and auth.uid() is not null and so.customer_user_id=auth.uid()) into verified;
  insert into public.store_product_reviews(business_id,product_id,reviewer_name,reviewer_email,rating,comment,review_status,verified_purchase,customer_user_id)
  values(b.id,p_product_id,trim(p_reviewer_name),lower(trim(p_reviewer_email)),p_rating,trim(p_comment),'pending',verified,auth.uid());
  return jsonb_build_object('success',true,'message','Thank you. Your review has been sent to the store for moderation.');
exception when unique_violation then raise exception 'You have already reviewed this product with that email address.';
end $$;

create or replace function public.merchant_get_store_reviews()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'product_id',r.product_id,'product_name',p.name,'reviewer_name',r.reviewer_name,'reviewer_email',r.reviewer_email,'rating',r.rating,'comment',r.comment,'status',r.review_status,'verified_purchase',r.verified_purchase,'merchant_reply',r.merchant_reply,'created_at',r.created_at) order by r.created_at desc),'[]'::jsonb)
 from public.store_product_reviews r join public.products p on p.id=r.product_id where r.business_id=public.my_business();
$$;
create or replace function public.merchant_moderate_store_review(p_review_id uuid,p_status text,p_reply text default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_status not in('approved','hidden') then raise exception 'Invalid review status.'; end if;
 update public.store_product_reviews set review_status=p_status,merchant_reply=nullif(trim(coalesce(p_reply,'')),''),replied_at=case when nullif(trim(coalesce(p_reply,'')),'') is null then replied_at else now() end
 where id=p_review_id and business_id=public.my_business();
 if not found then raise exception 'Review not found for this business.'; end if;
 return true;
end $$;
revoke all on function public.merchant_get_store_reviews() from public;
revoke all on function public.merchant_moderate_store_review(uuid,text,text) from public;
grant execute on function public.merchant_get_store_reviews() to authenticated;
grant execute on function public.merchant_moderate_store_review(uuid,text,text) to authenticated;

-- 3) General customer feedback, kept separate from product reviews.
create table if not exists public.store_customer_feedback (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 customer_user_id uuid references auth.users(id) on delete set null, customer_name text not null, customer_email text,
 category text not null default 'General' check(category in('General','Delivery','Customer service','Product quality','Website experience','Complaint')),
 message text not null check(char_length(trim(message)) between 5 and 2000), status text not null default 'open' check(status in('open','in_progress','resolved','closed')),
 merchant_reply text, replied_at timestamptz, created_at timestamptz not null default now()
);
create index if not exists store_customer_feedback_business_idx on public.store_customer_feedback(business_id,status,created_at desc);
alter table public.store_customer_feedback enable row level security;
revoke all on public.store_customer_feedback from anon,authenticated;
create or replace function public.submit_public_store_feedback(p_slug text,p_name text,p_email text,p_category text,p_message text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; fid uuid;
begin
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
 if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is unavailable.'; end if;
 if char_length(trim(coalesce(p_name,''))) not between 2 and 120 then raise exception 'Enter your name.'; end if;
 if p_category not in('General','Delivery','Customer service','Product quality','Website experience','Complaint') then raise exception 'Choose a feedback category.'; end if;
 if char_length(trim(coalesce(p_message,''))) not between 5 and 2000 then raise exception 'Feedback must be 5–2,000 characters.'; end if;
 insert into public.store_customer_feedback(business_id,customer_user_id,customer_name,customer_email,category,message)
 values(b.id,auth.uid(),trim(p_name),lower(nullif(trim(p_email),'')),p_category,trim(p_message)) returning id into fid;
 return jsonb_build_object('success',true,'id',fid,'message','Thank you. Your feedback has been sent to the store.');
end $$;
create or replace function public.merchant_get_customer_feedback()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'customer_name',f.customer_name,'customer_email',f.customer_email,'category',f.category,'message',f.message,'status',f.status,'merchant_reply',f.merchant_reply,'created_at',f.created_at) order by f.created_at desc),'[]'::jsonb)
 from public.store_customer_feedback f where f.business_id=public.my_business();
$$;
create or replace function public.merchant_reply_store_feedback(p_feedback_id uuid,p_status text,p_reply text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_status not in('open','in_progress','resolved','closed') then raise exception 'Invalid feedback status.'; end if;
 update public.store_customer_feedback set status=p_status,merchant_reply=nullif(trim(coalesce(p_reply,'')),''),replied_at=case when nullif(trim(coalesce(p_reply,'')),'') is null then replied_at else now() end
 where id=p_feedback_id and business_id=public.my_business();
 if not found then raise exception 'Feedback not found for this business.'; end if;
 return true;
end $$;
revoke all on function public.submit_public_store_feedback(text,text,text,text,text) from public;
revoke all on function public.merchant_get_customer_feedback() from public;
revoke all on function public.merchant_reply_store_feedback(uuid,text,text) from public;
grant execute on function public.submit_public_store_feedback(text,text,text,text,text) to anon,authenticated;
grant execute on function public.merchant_get_customer_feedback() to authenticated;
grant execute on function public.merchant_reply_store_feedback(uuid,text,text) to authenticated;

-- 4) Store analytics: anonymous session IDs only; no names, emails, phone numbers or form contents.
create table if not exists public.store_analytics_events (
 id bigint generated always as identity primary key, business_id uuid not null references public.businesses(id) on delete cascade,
 event_type text not null check(event_type in('store_view','product_view','add_to_cart','checkout_start','order_complete')),
 product_id uuid references public.products(id) on delete set null, session_key text not null,
 source text, created_at timestamptz not null default now()
);
create index if not exists store_analytics_business_date_idx on public.store_analytics_events(business_id,created_at desc);
alter table public.store_analytics_events enable row level security;
revoke all on public.store_analytics_events from anon,authenticated;
create or replace function public.track_public_store_event(p_slug text,p_event_type text,p_product_id uuid default null,p_session_key text default null,p_source text default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; sk text;
begin
 if p_event_type not in('store_view','product_view','add_to_cart','checkout_start','order_complete') then return false; end if;
 sk:=left(coalesce(nullif(p_session_key,''),'anonymous'),80);
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
 if not found or not public.has_orderdesk_access_for_business(b.id) then return false; end if;
 if p_product_id is not null and not exists(select 1 from public.products where id=p_product_id and business_id=b.id and store_published=true) then return false; end if;
 if (select count(*) from public.store_analytics_events where business_id=b.id and session_key=sk and created_at>=now()-interval '1 hour')>=120 then return false; end if;
 insert into public.store_analytics_events(business_id,event_type,product_id,session_key,source)
 values(b.id,p_event_type,p_product_id,sk,left(coalesce(p_source,''),80));
 return true;
end $$;
create or replace function public.merchant_get_store_analytics()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare bid uuid:=public.my_business();
begin
 return jsonb_build_object(
  'visitors_30d',(select count(distinct session_key) from public.store_analytics_events where business_id=bid and event_type='store_view' and created_at>=now()-interval '30 days'),
  'product_views_30d',(select count(*) from public.store_analytics_events where business_id=bid and event_type='product_view' and created_at>=now()-interval '30 days'),
  'cart_adds_30d',(select count(*) from public.store_analytics_events where business_id=bid and event_type='add_to_cart' and created_at>=now()-interval '30 days'),
  'checkout_starts_30d',(select count(*) from public.store_analytics_events where business_id=bid and event_type='checkout_start' and created_at>=now()-interval '30 days'),
  'top_sources',(select coalesce(jsonb_agg(jsonb_build_object('source',source,'visits',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(source,''),'direct') source,count(distinct session_key) n from public.store_analytics_events where business_id=bid and event_type='store_view' and created_at>=now()-interval '30 days' group by 1 limit 6) q),
  'top_products',(select coalesce(jsonb_agg(jsonb_build_object('product',p.name,'views',q.n) order by q.n desc),'[]'::jsonb) from (select product_id,count(*) n from public.store_analytics_events where business_id=bid and event_type='product_view' and created_at>=now()-interval '30 days' and product_id is not null group by product_id order by n desc limit 6) q join public.products p on p.id=q.product_id)
 );
end $$;
revoke all on function public.track_public_store_event(text,text,uuid,text,text) from public;
revoke all on function public.merchant_get_store_analytics() from public;
grant execute on function public.track_public_store_event(text,text,uuid,text,text) to anon,authenticated;
grant execute on function public.merchant_get_store_analytics() to authenticated;

-- 5) Product variations and delivery zones (merchant-managed, isolated per business).
create table if not exists public.store_product_variants (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete cascade, label text not null check(char_length(trim(label)) between 1 and 80),
 sku text, price numeric(12,2) check(price is null or price>=0), stock numeric(12,2) not null default 0 check(stock>=0), is_active boolean not null default true, created_at timestamptz not null default now()
);
create index if not exists store_product_variants_product_idx on public.store_product_variants(product_id,is_active);
alter table public.store_product_variants enable row level security;
drop policy if exists store_product_variants_owner on public.store_product_variants;
create policy store_product_variants_owner on public.store_product_variants for all to authenticated using(business_id=public.my_business()) with check(business_id=public.my_business());
grant select,insert,update,delete on public.store_product_variants to authenticated;

create table if not exists public.store_delivery_zones (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 zone_name text not null check(char_length(trim(zone_name)) between 2 and 100), delivery_fee numeric(12,2) not null default 0 check(delivery_fee>=0),
 estimated_days text, is_active boolean not null default true, created_at timestamptz not null default now(), unique(business_id,zone_name)
);
alter table public.store_delivery_zones enable row level security;
drop policy if exists store_delivery_zones_owner on public.store_delivery_zones;
create policy store_delivery_zones_owner on public.store_delivery_zones for all to authenticated using(business_id=public.my_business()) with check(business_id=public.my_business());
grant select,insert,update,delete on public.store_delivery_zones to authenticated;

create or replace function public.get_public_shop_options(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
 select * into b from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
 if not found or not public.has_orderdesk_access_for_business(b.id) then return jsonb_build_object('variants','[]'::jsonb,'delivery_zones','[]'::jsonb); end if;
 return jsonb_build_object(
  'variants',(select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'product_id',v.product_id,'label',v.label,'price',v.price,'stock',v.stock) order by v.label),'[]'::jsonb) from public.store_product_variants v join public.products p on p.id=v.product_id and p.store_published=true where v.business_id=b.id and v.is_active=true),
  'delivery_zones',(select coalesce(jsonb_agg(jsonb_build_object('id',z.id,'zone_name',z.zone_name,'delivery_fee',z.delivery_fee,'estimated_days',z.estimated_days) order by z.zone_name),'[]'::jsonb) from public.store_delivery_zones z where z.business_id=b.id and z.is_active=true)
 );
end $$;
revoke all on function public.get_public_shop_options(text) from public;
grant execute on function public.get_public_shop_options(text) to anon,authenticated;

-- 6) Merchant customer intelligence aggregates only customers who have ordered from this merchant.
create or replace function public.merchant_get_customer_insights()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare bid uuid:=public.my_business(); result jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('customer_name',x.customer_name,'customer_phone',x.customer_phone,'customer_email',x.customer_email,'orders',x.orders,'spend',x.spend,'last_order',x.last_order,'delivered_orders',x.delivered_orders,'has_orderdesk_account',x.has_orderdesk_account) order by x.spend desc),'[]'::jsonb)
 into result from (
  select coalesce(nullif(max(cp.full_name),''),max(so.customer_name)) customer_name,coalesce(max(cp.phone),max(so.customer_phone)) customer_phone,coalesce(max(cp.email),max(so.customer_email)) customer_email,count(*)::int orders,sum(so.total)::numeric spend,max(so.created_at) last_order,count(*) filter(where so.status='Delivered')::int delivered_orders,bool_or(so.customer_user_id is not null) has_orderdesk_account
  from public.store_orders so left join public.store_customer_profiles cp on cp.user_id=so.customer_user_id
  where so.business_id=bid group by coalesce(so.customer_user_id::text,lower(coalesce(so.customer_email,'')||'|'||so.customer_phone))
 ) x;
 return result;
end $$;
revoke all on function public.merchant_get_customer_insights() from public;
grant execute on function public.merchant_get_customer_insights() to authenticated;

-- Public product/store feedback functions are deliberately separate from customer account data.
revoke all on function public.get_public_shop_reviews(text) from public;
revoke all on function public.submit_public_product_review(text,uuid,text,text,integer,text) from public;
grant execute on function public.get_public_shop_reviews(text) to anon,authenticated;
grant execute on function public.submit_public_product_review(text,uuid,text,text,integer,text) to anon,authenticated;
commit;

-- Notes:
-- * Guest checkout remains available. Signed-in customers are linked to orders automatically.
-- * Universal customer accounts use the same Supabase Auth identity across every OrderDesk shop.
-- * Variants and delivery zones are stored per merchant. Checkout/pricing integration is a separate controlled step;
--   do not enable them as customer-selectable checkout options until the checkout RPC update is validated.
-- * Review moderation is enabled; existing reviews are grandfathered as approved.
