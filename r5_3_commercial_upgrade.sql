-- OrderDesk NG R5.3 Commercial Upgrade Foundation
-- ADDITIVE ONLY. Apply first to a separate test Supabase project after the existing R5.2 migrations.
-- No existing order, customer, product, or payment rows are deleted or rewritten.
begin;

-- Subscription payment details are configured by the platform owner, never hardcoded.
create table if not exists public.platform_payment_settings (id integer primary key default 1 check(id=1),commission_percent numeric(5,2) not null default 5);
insert into public.platform_payment_settings(id,commission_percent) values(1,5) on conflict(id) do nothing;
alter table public.platform_payment_settings add column if not exists subscription_bank_name text;
alter table public.platform_payment_settings add column if not exists subscription_account_name text;
alter table public.platform_payment_settings add column if not exists subscription_account_number text;
alter table public.platform_payment_settings add column if not exists subscription_payment_instructions text;
alter table public.platform_payment_settings add column if not exists subscription_payment_enabled boolean not null default false;

-- Commercial plan catalogue. Limits are configurable by the platform owner.
create table if not exists public.orderdesk_plan_config (
  plan_code text primary key check (plan_code in ('free','essentials','standard')),
  display_name text not null,
  monthly_price_ngn numeric(12,2) not null check (monthly_price_ngn >= 0),
  ai_text_units integer not null default 0 check (ai_text_units >= 0),
  ai_image_units integer not null default 0 check (ai_image_units >= 0),
  advanced_store_tools boolean not null default false,
  advanced_reports boolean not null default false,
  growth_studio boolean not null default false,
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.orderdesk_plan_config(plan_code,display_name,monthly_price_ngn,ai_text_units,ai_image_units,advanced_store_tools,advanced_reports,growth_studio)
values
 ('free','Free',0,20,0,false,false,false),
 ('essentials','Essentials',10000,200,0,false,false,false),
 ('standard','Standard',15000,800,30,true,true,true)
on conflict(plan_code) do nothing;
do $$ begin
 if not exists(select 1 from pg_constraint where conname='orderdesk_plan_image_quota_standard_only') then
  alter table public.orderdesk_plan_config add constraint orderdesk_plan_image_quota_standard_only check(plan_code='standard' or ai_image_units=0);
 end if;
end $$;
alter table public.orderdesk_plan_config enable row level security;
drop policy if exists orderdesk_plan_config_public_read on public.orderdesk_plan_config;
create policy orderdesk_plan_config_public_read on public.orderdesk_plan_config for select to anon,authenticated using(is_active);
drop policy if exists orderdesk_plan_config_owner_update on public.orderdesk_plan_config;
create policy orderdesk_plan_config_owner_update on public.orderdesk_plan_config for all to authenticated
 using(auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid)
 with check(auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid);
grant select on public.orderdesk_plan_config to anon,authenticated;
grant insert,update,delete on public.orderdesk_plan_config to authenticated;

-- A prepaid subscription's start/end dates define which monthly AI periods are actually covered.
alter table public.subscriptions add column if not exists billing_period_months integer not null default 1;
alter table public.subscriptions add column if not exists paid_amount_ngn numeric(12,2);
alter table public.subscriptions add column if not exists payment_verified_at timestamptz;
alter table public.subscriptions add column if not exists created_at timestamptz not null default now();
alter table public.subscriptions add column if not exists payment_reference text;
do $$ begin
 if not exists(select 1 from pg_constraint where conname='subscriptions_billing_period_months_check') then
  alter table public.subscriptions add constraint subscriptions_billing_period_months_check check(billing_period_months in (1,3,6,12));
 end if;
end $$;

create table if not exists public.orderdesk_ai_usage (
 id bigint generated always as identity primary key,
 business_id uuid not null references public.businesses(id) on delete cascade,
 provider text not null check(provider in ('groq_text','gemini_image')),
 period_start timestamptz not null,
 period_end timestamptz not null,
 used_units integer not null default 0 check(used_units >= 0),
 updated_at timestamptz not null default now(),
 unique(business_id,provider,period_start),
 check(period_end > period_start)
);
alter table public.orderdesk_ai_usage alter column period_end drop not null;
create index if not exists orderdesk_ai_usage_business_period_idx on public.orderdesk_ai_usage(business_id,period_start desc);
alter table public.orderdesk_ai_usage enable row level security;
drop policy if exists orderdesk_ai_usage_owner_read on public.orderdesk_ai_usage;
create policy orderdesk_ai_usage_owner_read on public.orderdesk_ai_usage for select to authenticated
 using(business_id=public.my_business());
grant select on public.orderdesk_ai_usage to authenticated;

-- One source of truth for effective plan entitlements. Expired paid plans fall back to Free.
create or replace function public.get_orderdesk_entitlements()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; s public.subscriptions%rowtype; p public.orderdesk_plan_config%rowtype; plan_key text; is_paid boolean:=false;
begin
 if auth.uid() is null then raise exception 'Sign in to view plan entitlements.'; end if;
 select * into b from public.businesses where owner_id=auth.uid() limit 1;
 if not found then raise exception 'Business account not found.'; end if;
 if auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then return jsonb_build_object('plan','standard','plan_name','Platform owner','monthly_price_ngn',0,'is_paid_period',true,'subscription_ends_at',null,'billing_period_months',1,'ai_text_units',2147483647,'ai_image_units',2147483647,'advanced_store_tools',true,'advanced_reports',true,'growth_studio',true); end if;
 select * into s from public.subscriptions where business_id=b.id and lower(coalesce(status,''))='active' and ends_at>now() and coalesce(started_at,now())<=now() order by ends_at desc limit 1;
 if found then plan_key:=lower(coalesce(s.plan,'free')); if plan_key in ('monthly','growth') then plan_key:='essentials'; end if; is_paid:=plan_key in ('essentials','standard');
 else plan_key:='free'; end if;
 if plan_key not in ('free','essentials','standard') then plan_key:='free'; is_paid:=false; end if;
 select * into p from public.orderdesk_plan_config where plan_code=plan_key and is_active;
 if not found then select * into p from public.orderdesk_plan_config where plan_code='free'; plan_key:='free'; is_paid:=false; end if;
 return jsonb_build_object('plan',plan_key,'plan_name',p.display_name,'monthly_price_ngn',p.monthly_price_ngn,
  'is_paid_period',is_paid,'subscription_ends_at',case when is_paid then s.ends_at else null end,
  'billing_period_months',case when is_paid then coalesce(s.billing_period_months,1) else 1 end,
  'ai_text_units',p.ai_text_units,'ai_image_units',p.ai_image_units,
  'advanced_store_tools',p.advanced_store_tools,'advanced_reports',p.advanced_reports,'growth_studio',p.growth_studio);
end $$;
revoke all on function public.get_orderdesk_entitlements() from public;
grant execute on function public.get_orderdesk_entitlements() to authenticated;

-- Feature gate used by both merchant UI and database row-level security.
create or replace function public.has_orderdesk_feature(p_feature text)
returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
declare ent jsonb;
begin
 if auth.uid() is null then return false; end if;
 if auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then return true; end if;
 ent:=public.get_orderdesk_entitlements();
 case p_feature
  when 'advanced_store_tools' then return coalesce((ent->>'advanced_store_tools')::boolean,false);
  when 'advanced_reports' then return coalesce((ent->>'advanced_reports')::boolean,false);
  when 'growth_studio' then return coalesce((ent->>'growth_studio')::boolean,false);
  else return false;
 end case;
end $$;
revoke all on function public.has_orderdesk_feature(text) from public;
grant execute on function public.has_orderdesk_feature(text) to authenticated;

-- Standard-only data is protected at the database layer, not merely hidden in the interface.
do $$ declare t text; begin
 foreach t in array array['catalog_option_groups','catalog_option_values','catalog_variants','catalog_modifier_groups','catalog_modifiers','inventory_batches','inventory_serials','catalog_bundle_items','service_bookings'] loop
  execute format('drop policy if exists %I on public.%I',t||'_owner_all',t);
  execute format('create policy %I on public.%I for all to authenticated using (business_id=public.my_business() and public.has_orderdesk_feature(''advanced_store_tools'')) with check (business_id=public.my_business() and public.has_orderdesk_feature(''advanced_store_tools''))',t||'_owner_all',t);
 end loop;
end $$;

create table if not exists public.orderdesk_ai_usage_reservations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 provider text not null check(provider in ('groq_text','gemini_image')),
 period_start timestamptz not null,
 units integer not null default 1 check(units>=1),
 status text not null default 'reserved' check(status in ('reserved','committed','released')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);
alter table public.orderdesk_ai_usage_reservations enable row level security;
revoke all on public.orderdesk_ai_usage_reservations from anon,authenticated;

-- Atomic allowance consumption. Paid merchants get one allowance per prepaid monthly period;
-- no rollover, no renewal beyond ends_at, and no calendar-based renewal. Free receives one starter allowance only.
create or replace function public.consume_orderdesk_ai_usage(p_provider text,p_units integer default 1)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; s public.subscriptions%rowtype; cfg public.orderdesk_plan_config%rowtype;
 plan_key text; quota integer; v_used integer; v_period_start timestamptz; v_period_end timestamptz; month_no integer; v_reservation uuid; stale record;
begin
 if auth.uid() is null then raise exception 'Sign in to use OrderDesk AI.'; end if;
 if p_provider not in ('groq_text','gemini_image') then raise exception 'Unsupported AI provider.'; end if;
 if p_units is null or p_units<1 or p_units>20 then raise exception 'Invalid AI usage amount.'; end if;
 select * into b from public.businesses where owner_id=auth.uid() limit 1;
 if not found then raise exception 'Business account not found.'; end if;
 if auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then return jsonb_build_object('allowed',true,'plan','standard','provider',p_provider,'used',0,'limit',2147483647,'remaining',2147483647,'period_start',date_trunc('month',now()),'period_ends_at',date_trunc('month',now())+interval '1 month','reservation_id',null); end if;
 -- Release abandoned provider reservations from timed-out requests after ten minutes.
 for stale in select * from public.orderdesk_ai_usage_reservations where business_id=b.id and status='reserved' and created_at<now()-interval '10 minutes' for update loop
  update public.orderdesk_ai_usage_reservations set status='released',resolved_at=now() where id=stale.id;
  update public.orderdesk_ai_usage set used_units=greatest(0,used_units-stale.units),updated_at=now() where business_id=b.id and provider=stale.provider and period_start=stale.period_start;
 end loop;
 select * into s from public.subscriptions where business_id=b.id and lower(coalesce(status,''))='active' and ends_at>now() and coalesce(started_at,now())<=now() order by ends_at desc limit 1;
 if found then
  plan_key:=lower(coalesce(s.plan,'free'));
  if plan_key in ('monthly','growth') then plan_key:='essentials'; end if;
  if plan_key not in ('essentials','standard') then plan_key:='free'; end if;
  month_no:=greatest(0,(extract(year from now())::integer-extract(year from coalesce(s.started_at,now()))::integer)*12+(extract(month from now())::integer-extract(month from coalesce(s.started_at,now()))::integer));
  if coalesce(s.started_at,now())+make_interval(months=>month_no)>now() then month_no:=greatest(0,month_no-1); end if;
  v_period_start:=coalesce(s.started_at,now())+make_interval(months=>month_no);
  v_period_end:=least(v_period_start+interval '1 month',s.ends_at);
  if v_period_start>now() or v_period_start>=s.ends_at or v_period_end<=now() then raise exception 'Your paid service period is not active. Renew your subscription to restore AI.'; end if;
 else
  plan_key:='free';
  -- Free AI is a one-time starter allowance; it does not refresh without a paid period.
  v_period_start:=coalesce(b.created_at,now());
  v_period_end:=null;
 end if;
 select * into cfg from public.orderdesk_plan_config where plan_code=plan_key and is_active;
 if not found then raise exception 'AI plan configuration is unavailable.'; end if;
 quota:=case when p_provider='gemini_image' and cfg.growth_studio then cfg.ai_image_units when p_provider='gemini_image' then 0 else cfg.ai_text_units end;
 insert into public.orderdesk_ai_usage(business_id,provider,period_start,period_end,used_units)
 values(b.id,p_provider,v_period_start,v_period_end,0)
 on conflict(business_id,provider,period_start) do nothing;
 update public.orderdesk_ai_usage u set used_units=u.used_units+p_units,period_end=v_period_end,updated_at=now()
 where u.business_id=b.id and u.provider=p_provider and u.period_start=v_period_start and u.used_units+p_units<=quota
 returning u.used_units into v_used;
 if not found then
  select u.used_units into v_used from public.orderdesk_ai_usage u where u.business_id=b.id and u.provider=p_provider and u.period_start=v_period_start;
  return jsonb_build_object('allowed',false,'plan',plan_key,'provider',p_provider,'used',coalesce(v_used,0),'limit',quota,'remaining',greatest(0,quota-coalesce(v_used,0)),'period_start',v_period_start,'period_ends_at',v_period_end,'reason',case when quota=0 then 'not_included' else 'allowance_exhausted' end);
 end if;
 insert into public.orderdesk_ai_usage_reservations(business_id,provider,period_start,units) values(b.id,p_provider,v_period_start,p_units) returning id into v_reservation;
 return jsonb_build_object('allowed',true,'plan',plan_key,'provider',p_provider,'used',v_used,'limit',quota,'remaining',greatest(0,quota-v_used),'period_start',v_period_start,'period_ends_at',v_period_end,'reservation_id',v_reservation);
end $$;
revoke all on function public.consume_orderdesk_ai_usage(text,integer) from public;
grant execute on function public.consume_orderdesk_ai_usage(text,integer) to authenticated;

-- Public central marketplace search. Only published products from enabled stores are discoverable.
create or replace function public.search_orderdesk_marketplace(p_query text default null,p_category text default null,p_limit integer default 48)
returns table(product_id uuid,business_id uuid,product_name text,description text,category text,price numeric,currency text,image_url text,shop_name text,shop_slug text,logo_url text)
language sql stable security definer set search_path=public,pg_temp as $$
 select p.id,b.id,p.name,p.description,p.category,p.price,coalesce(b.currency,'NGN'),p.image_url,
        coalesce(b.shop_name,b.name),b.shop_slug,b.logo_url
 from public.products p join public.businesses b on b.id=p.business_id
 where b.store_enabled=true and nullif(trim(b.shop_slug),'') is not null and p.store_published=true
   and public.has_orderdesk_access_for_business(b.id)
   and (nullif(trim(coalesce(p_query,'')),'') is null or (p.name||' '||coalesce(p.description,'')||' '||coalesce(p.category,'')) ilike '%'||trim(p_query)||'%')
   and (nullif(trim(coalesce(p_category,'')),'') is null or coalesce(p.category,'') ilike trim(p_category))
 order by p.created_at desc limit greatest(1,least(coalesce(p_limit,48),100));
$$;
revoke all on function public.search_orderdesk_marketplace(text,text,integer) from public;
grant execute on function public.search_orderdesk_marketplace(text,text,integer) to anon,authenticated;


-- Commercial plan payment requests, manually verified by the platform owner.
create table if not exists public.commercial_subscription_requests (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 plan_code text not null references public.orderdesk_plan_config(plan_code),
 billing_period_months integer not null check(billing_period_months in (1,3,6,12)),
 amount_ngn numeric(12,2) not null check(amount_ngn>0),
 transaction_reference text not null,
 receipt_path text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 rejection_note text,
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create index if not exists commercial_subscription_requests_business_idx on public.commercial_subscription_requests(business_id,created_at desc);
create unique index if not exists commercial_subscription_requests_one_pending_idx on public.commercial_subscription_requests(business_id) where status='pending';
alter table public.commercial_subscription_requests enable row level security;
drop policy if exists commercial_subscription_requests_owner_read on public.commercial_subscription_requests;
create policy commercial_subscription_requests_owner_read on public.commercial_subscription_requests for select to authenticated
 using(business_id=public.my_business());
grant select on public.commercial_subscription_requests to authenticated;

create or replace function public.customer_submit_commercial_payment_request(p_plan_code text,p_months integer,p_transaction_reference text,p_receipt_path text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; cfg public.orderdesk_plan_config%rowtype; v_amount numeric(12,2); v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in before submitting a subscription payment.'; end if;
 if not exists(select 1 from public.platform_payment_settings where id=1 and subscription_payment_enabled=true and nullif(trim(subscription_bank_name),'') is not null and nullif(trim(subscription_account_name),'') is not null and length(regexp_replace(coalesce(subscription_account_number,''),'\D','','g'))=10) then raise exception 'Subscription payment instructions are not configured yet. Contact the platform owner.'; end if;
 if p_plan_code not in ('essentials','standard') or p_months not in (1,3,6,12) then raise exception 'Choose a valid paid plan and duration.'; end if;
 if length(trim(coalesce(p_transaction_reference,'')))<4 or length(trim(coalesce(p_transaction_reference,'')))>120 then raise exception 'Enter a valid transfer reference.'; end if;
 select * into b from public.businesses where owner_id=auth.uid() limit 1;
 if not found then raise exception 'Business account not found.'; end if;
 if coalesce(p_receipt_path,'') not like b.id::text||'/%' then raise exception 'Invalid payment receipt path.'; end if;
 select * into cfg from public.orderdesk_plan_config where plan_code=p_plan_code and is_active;
 if not found then raise exception 'This plan is not available.'; end if;
 v_amount:=cfg.monthly_price_ngn * case p_months when 1 then 1 when 3 then 2.85 when 6 then 5.4 when 12 then 10.2 end;
 if exists(select 1 from public.commercial_subscription_requests where business_id=b.id and status='pending') then raise exception 'You already have a payment awaiting review.'; end if;
 insert into public.commercial_subscription_requests(business_id,plan_code,billing_period_months,amount_ngn,transaction_reference,receipt_path)
 values(b.id,p_plan_code,p_months,round(v_amount,2),trim(p_transaction_reference),p_receipt_path) returning id into v_id;
 return v_id;
end $$;
revoke all on function public.customer_submit_commercial_payment_request(text,integer,text,text) from public;
grant execute on function public.customer_submit_commercial_payment_request(text,integer,text,text) to authenticated;

create or replace function public.owner_list_commercial_subscription_requests()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
 if auth.uid()<>'327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then raise exception 'Not authorised.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'business_id',r.business_id,'business_name',b.name,'owner_name',b.owner_name,'business_email',b.email,'plan_code',r.plan_code,'billing_period_months',r.billing_period_months,'amount_ngn',r.amount_ngn,'transaction_reference',r.transaction_reference,'receipt_path',r.receipt_path,'status',r.status,'rejection_note',r.rejection_note,'created_at',r.created_at) order by r.created_at desc),'[]'::jsonb)
 into result from public.commercial_subscription_requests r join public.businesses b on b.id=r.business_id;
 return result;
end $$;
revoke all on function public.owner_list_commercial_subscription_requests() from public;
grant execute on function public.owner_list_commercial_subscription_requests() to authenticated;

create or replace function public.owner_decide_commercial_subscription_request(p_request_id uuid,p_decision text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.commercial_subscription_requests%rowtype; v_start timestamptz; v_end timestamptz; existing_end timestamptz;
begin
 if auth.uid()<>'327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then raise exception 'Not authorised.'; end if;
 if p_decision not in ('approve','reject') then raise exception 'Invalid decision.'; end if;
 select * into r from public.commercial_subscription_requests where id=p_request_id for update;
 if not found or r.status<>'pending' then raise exception 'This payment request is no longer pending.'; end if;
 if p_decision='reject' then
  update public.commercial_subscription_requests set status='rejected',rejection_note=left(trim(coalesce(p_note,'Payment could not be verified.')),500),reviewed_at=now(),reviewed_by=auth.uid() where id=r.id;
  return jsonb_build_object('success',true,'status','rejected');
 end if;
 select max(ends_at) into existing_end from public.subscriptions where business_id=r.business_id and lower(status)='active' and ends_at>now();
 v_start:=greatest(now(),coalesce(existing_end,now()));
 v_end:=v_start+make_interval(months=>r.billing_period_months);
 insert into public.subscriptions(business_id,plan,status,reference,started_at,ends_at,billing_period_months,paid_amount_ngn,payment_verified_at,payment_reference)
 values(r.business_id,r.plan_code,'active',r.transaction_reference,v_start,v_end,r.billing_period_months,r.amount_ngn,now(),r.transaction_reference);
 update public.businesses set plan=r.plan_code where id=r.business_id;
 update public.commercial_subscription_requests set status='approved',reviewed_at=now(),reviewed_by=auth.uid(),rejection_note=null where id=r.id;
 return jsonb_build_object('success',true,'status','approved','plan',r.plan_code,'started_at',v_start,'ends_at',v_end,'billing_period_months',r.billing_period_months);
end $$;
revoke all on function public.owner_decide_commercial_subscription_request(uuid,text,text) from public;
grant execute on function public.owner_decide_commercial_subscription_request(uuid,text,text) to authenticated;


-- Reservations can be committed once on provider success or released once on provider failure.
-- The one-time state transition prevents a merchant from repeatedly refunding successful AI calls.
create or replace function public.commit_orderdesk_ai_usage(p_reservation_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare bid uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required.'; end if;
 select id into bid from public.businesses where owner_id=auth.uid() limit 1;
 if bid is null then raise exception 'Business account not found.'; end if;
 update public.orderdesk_ai_usage_reservations set status='committed',resolved_at=now()
 where id=p_reservation_id and business_id=bid and status='reserved';
 return found;
end $$;
revoke all on function public.commit_orderdesk_ai_usage(uuid) from public;
grant execute on function public.commit_orderdesk_ai_usage(uuid) to authenticated;

create or replace function public.refund_orderdesk_ai_usage(p_reservation_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare bid uuid; r public.orderdesk_ai_usage_reservations%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in required.'; end if;
 select id into bid from public.businesses where owner_id=auth.uid() limit 1;
 if bid is null then raise exception 'Business account not found.'; end if;
 select * into r from public.orderdesk_ai_usage_reservations where id=p_reservation_id and business_id=bid and status='reserved' for update;
 if not found then return false; end if;
 update public.orderdesk_ai_usage_reservations set status='released',resolved_at=now() where id=r.id;
 update public.orderdesk_ai_usage set used_units=greatest(0,used_units-r.units),updated_at=now()
 where business_id=bid and provider=r.provider and period_start=r.period_start;
 return true;
end $$;
revoke all on function public.refund_orderdesk_ai_usage(uuid) from public;
grant execute on function public.refund_orderdesk_ai_usage(uuid) to authenticated;

create or replace function public.get_orderdesk_ai_usage()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; s public.subscriptions%rowtype; ent jsonb; plan_key text; cfg public.orderdesk_plan_config%rowtype;
 v_start timestamptz; v_end timestamptz; month_no integer; text_used integer:=0; image_used integer:=0;
begin
 if auth.uid() is null then raise exception 'Sign in to view AI usage.'; end if;
 select * into b from public.businesses where owner_id=auth.uid() limit 1;
 if not found then raise exception 'Business account not found.'; end if;
 if auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then return jsonb_build_object('plan','standard','text_limit',2147483647,'text_used',0,'text_remaining',2147483647,'image_limit',2147483647,'image_used',0,'image_remaining',2147483647,'period_start',date_trunc('month',now()),'period_ends_at',date_trunc('month',now())+interval '1 month','paid_period',true); end if;
 select * into s from public.subscriptions where business_id=b.id and lower(coalesce(status,''))='active' and ends_at>now() and coalesce(started_at,now())<=now() order by ends_at desc limit 1;
 if found then
  plan_key:=lower(coalesce(s.plan,'free')); if plan_key in ('monthly','growth') then plan_key:='essentials'; end if;
  if plan_key not in ('essentials','standard') then plan_key:='free'; end if;
  month_no:=greatest(0,(extract(year from now())::integer-extract(year from coalesce(s.started_at,now()))::integer)*12+(extract(month from now())::integer-extract(month from coalesce(s.started_at,now()))::integer));
  if coalesce(s.started_at,now())+make_interval(months=>month_no)>now() then month_no:=greatest(0,month_no-1); end if;
  v_start:=coalesce(s.started_at,now())+make_interval(months=>month_no);v_end:=least(v_start+interval '1 month',s.ends_at);
 else plan_key:='free';v_start:=coalesce(b.created_at,now());v_end:=null;end if;
 select * into cfg from public.orderdesk_plan_config where plan_code=plan_key;
 select coalesce(max(used_units),0) into text_used from public.orderdesk_ai_usage where business_id=b.id and provider='groq_text' and period_start=v_start;
 select coalesce(max(used_units),0) into image_used from public.orderdesk_ai_usage where business_id=b.id and provider='gemini_image' and period_start=v_start;
 return jsonb_build_object('plan',plan_key,'text_limit',cfg.ai_text_units,'text_used',text_used,'text_remaining',greatest(0,cfg.ai_text_units-text_used),'image_limit',cfg.ai_image_units,'image_used',image_used,'image_remaining',greatest(0,cfg.ai_image_units-image_used),'period_start',v_start,'period_ends_at',v_end,'paid_period',plan_key<>'free');
end $$;
revoke all on function public.get_orderdesk_ai_usage() from public;
grant execute on function public.get_orderdesk_ai_usage() to authenticated;


-- Customer account additions: followed stores, service bookings and paid digital purchases.
create table if not exists public.store_customer_favourite_stores (
 user_id uuid not null references auth.users(id) on delete cascade,
 business_id uuid not null references public.businesses(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(user_id,business_id)
);
alter table public.store_customer_favourite_stores enable row level security;
drop policy if exists store_customer_favourites_self on public.store_customer_favourite_stores;
create policy store_customer_favourites_self on public.store_customer_favourite_stores for all to authenticated
 using(user_id=auth.uid()) with check(user_id=auth.uid());
grant select,insert,delete on public.store_customer_favourite_stores to authenticated;

create or replace function public.follow_orderdesk_store(p_slug text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare bid uuid;
begin
 if auth.uid() is null then raise exception 'Sign in to follow a store.'; end if;
 select id into bid from public.businesses where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true and public.has_orderdesk_access_for_business(id) limit 1;
 if bid is null then raise exception 'This store is not currently available.'; end if;
 insert into public.store_customer_favourite_stores(user_id,business_id) values(auth.uid(),bid) on conflict do nothing;
 return true;
end $$;
revoke all on function public.follow_orderdesk_store(text) from public;
grant execute on function public.follow_orderdesk_store(text) to authenticated;

create or replace function public.unfollow_orderdesk_store(p_business_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'Sign in to manage followed stores.'; end if;
 delete from public.store_customer_favourite_stores where user_id=auth.uid() and business_id=p_business_id;
 return found;
end $$;
revoke all on function public.unfollow_orderdesk_store(uuid) from public;
grant execute on function public.unfollow_orderdesk_store(uuid) to authenticated;

create or replace function public.get_my_store_customer_data()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare prof jsonb; ord jsonb; wish jsonb; addr jsonb; fav jsonb; bookings jsonb; digital jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in to view your customer account.'; end if;
 select to_jsonb(p) into prof from public.store_customer_profiles p where p.user_id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('order_ref',so.order_ref,'shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'status',so.status,'payment_status',so.payment_status,'payment_method',so.payment_method,'subtotal',so.subtotal,'delivery_fee',so.delivery_fee,'delivery_zone_name',so.delivery_zone_name,'total',so.total,'created_at',so.created_at,'delivery_address',so.delivery_address,'items',coalesce((select jsonb_agg(jsonb_build_object('product_name',i.product_name,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total,'selected_options',i.selected_options,'modifiers_snapshot',i.modifiers_snapshot,'sku_snapshot',i.sku_snapshot) order by i.product_name) from public.store_order_items i where i.store_order_id=so.id),'[]'::jsonb)) order by so.created_at desc),'[]'::jsonb)
 into ord from public.store_orders so join public.businesses b on b.id=so.business_id where so.customer_user_id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('product_id',w.product_id,'business_id',w.business_id,'product_name',p.name,'shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'price',p.price,'image_url',p.image_url) order by w.created_at desc),'[]'::jsonb)
 into wish from public.store_customer_wishlist w join public.products p on p.id=w.product_id join public.businesses b on b.id=w.business_id where w.user_id=auth.uid() and p.store_published=true;
 select coalesce(jsonb_agg(to_jsonb(a) order by a.is_default desc,a.created_at desc),'[]'::jsonb) into addr from public.store_customer_addresses a where a.user_id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('business_id',b.id,'shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'logo_url',b.logo_url) order by f.created_at desc),'[]'::jsonb)
 into fav from public.store_customer_favourite_stores f join public.businesses b on b.id=f.business_id where f.user_id=auth.uid() and b.store_enabled=true;
 select coalesce(jsonb_agg(jsonb_build_object('shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'product_name',coalesce(p.name,'Service'),'starts_at',sb.starts_at,'ends_at',sb.ends_at,'status',sb.status,'order_ref',so.order_ref) order by sb.starts_at desc),'[]'::jsonb)
 into bookings from public.service_bookings sb join public.store_orders so on so.id=sb.store_order_id join public.businesses b on b.id=sb.business_id left join public.products p on p.id=sb.product_id where so.customer_user_id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('shop_name',coalesce(b.shop_name,b.name),'shop_slug',b.shop_slug,'order_ref',so.order_ref,'product_name',d.product_name,'delivery_content',d.delivery_content,'created_at',d.created_at) order by d.created_at desc),'[]'::jsonb)
 into digital from public.store_order_digital_deliveries d join public.store_orders so on so.id=d.store_order_id join public.businesses b on b.id=d.business_id where so.customer_user_id=auth.uid() and so.payment_status='Confirmed' and so.status<>'Cancelled';
 return jsonb_build_object('profile',coalesce(prof,'{}'::jsonb),'orders',coalesce(ord,'[]'::jsonb),'wishlist',coalesce(wish,'[]'::jsonb),'addresses',coalesce(addr,'[]'::jsonb),'favourite_stores',coalesce(fav,'[]'::jsonb),'bookings',coalesce(bookings,'[]'::jsonb),'digital_purchases',coalesce(digital,'[]'::jsonb));
end $$;
revoke all on function public.get_my_store_customer_data() from public;
grant execute on function public.get_my_store_customer_data() to authenticated;


-- Deduplication log for scheduled subscription-expiry reminders (service-role function only).
create table if not exists public.orderdesk_subscription_reminder_logs (
 id bigint generated always as identity primary key,
 subscription_id uuid not null references public.subscriptions(id) on delete cascade,
 business_id uuid not null references public.businesses(id) on delete cascade,
 days_remaining integer not null check(days_remaining in (7,3,1,0)),
 sent_at timestamptz not null default now(),
 unique(subscription_id,days_remaining)
);
alter table public.orderdesk_subscription_reminder_logs enable row level security;
revoke all on public.orderdesk_subscription_reminder_logs from anon,authenticated;


-- Private receipt storage for the commercial payment workflow.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('subscription-receipts','subscription-receipts',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists orderdesk_subscription_receipts_owner_upload on storage.objects;
create policy orderdesk_subscription_receipts_owner_upload on storage.objects for insert to authenticated
 with check(bucket_id='subscription-receipts' and (storage.foldername(name))[1]=(select b.id::text from public.businesses b where b.owner_id=auth.uid() limit 1));
drop policy if exists orderdesk_subscription_receipts_owner_read on storage.objects;
create policy orderdesk_subscription_receipts_owner_read on storage.objects for select to authenticated
 using(bucket_id='subscription-receipts' and ((storage.foldername(name))[1]=(select b.id::text from public.businesses b where b.owner_id=auth.uid() limit 1) or auth.uid()='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid));


-- R5.0 and R5.2 used different names for delivery-zone columns. Keep both pairs synchronized.
alter table public.store_delivery_zones add column if not exists name text;
alter table public.store_delivery_zones add column if not exists fee numeric(12,2);
alter table public.store_delivery_zones add column if not exists zone_name text;
alter table public.store_delivery_zones add column if not exists delivery_fee numeric(12,2);
alter table public.store_delivery_zones add column if not exists estimated_days text;
update public.store_delivery_zones set name=coalesce(nullif(trim(name),''),nullif(trim(zone_name),'')),zone_name=coalesce(nullif(trim(zone_name),''),nullif(trim(name),'')),fee=coalesce(fee,delivery_fee,0),delivery_fee=coalesce(delivery_fee,fee,0);
alter table public.store_delivery_zones alter column name set not null;
alter table public.store_delivery_zones alter column fee set not null;
alter table public.store_delivery_zones alter column zone_name set not null;
alter table public.store_delivery_zones alter column delivery_fee set not null;
create unique index if not exists store_delivery_zones_business_name_uidx on public.store_delivery_zones(business_id,name);
create or replace function public.sync_orderdesk_delivery_zone_columns()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' then
  new.name:=coalesce(nullif(trim(new.name),''),nullif(trim(new.zone_name),''));new.zone_name:=coalesce(nullif(trim(new.zone_name),''),new.name);
  new.fee:=coalesce(new.fee,new.delivery_fee,0);new.delivery_fee:=coalesce(new.delivery_fee,new.fee,0);
 else
  if new.name is distinct from old.name and new.zone_name is not distinct from old.zone_name then new.zone_name:=new.name;
  elsif new.zone_name is distinct from old.zone_name and new.name is not distinct from old.name then new.name:=new.zone_name;
  else new.name:=coalesce(nullif(trim(new.name),''),new.zone_name);new.zone_name:=coalesce(nullif(trim(new.zone_name),''),new.name);end if;
  if new.fee is distinct from old.fee and new.delivery_fee is not distinct from old.delivery_fee then new.delivery_fee:=new.fee;
  elsif new.delivery_fee is distinct from old.delivery_fee and new.fee is not distinct from old.fee then new.fee:=new.delivery_fee;
  else new.fee:=coalesce(new.fee,new.delivery_fee,0);new.delivery_fee:=coalesce(new.delivery_fee,new.fee,0);end if;
 end if;
 return new;
end $$;
drop trigger if exists orderdesk_sync_delivery_zone_columns on public.store_delivery_zones;
create trigger orderdesk_sync_delivery_zone_columns before insert or update on public.store_delivery_zones for each row execute function public.sync_orderdesk_delivery_zone_columns();

-- Link stock allocations to order items and source batches/serial numbers for traceability.
alter table public.store_order_inventory_allocations add column if not exists batch_id uuid references public.inventory_batches(id) on delete restrict;
alter table public.store_order_inventory_allocations add column if not exists store_order_item_id uuid references public.store_order_items(id) on delete set null;
do $$ declare c record; begin
 for c in select conname from pg_constraint where conrelid='public.store_order_inventory_allocations'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%allocation_kind%' loop
  execute format('alter table public.store_order_inventory_allocations drop constraint %I',c.conname);
 end loop;
end $$;
alter table public.store_order_inventory_allocations add constraint store_order_inventory_allocations_kind_check check(allocation_kind in ('product','variant','bundle_component','batch','serial'));
alter table public.inventory_serials add column if not exists store_order_id uuid references public.store_orders(id) on delete set null;
alter table public.inventory_serials add column if not exists store_order_item_id uuid references public.store_order_items(id) on delete set null;
alter table public.inventory_serials add column if not exists sold_at timestamptz;

create or replace function public.reserve_orderdesk_product_inventory(p_business_id uuid,p_product_id uuid,p_quantity numeric,p_order_id uuid,p_order_item_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.products%rowtype; batch record; remaining numeric; take_qty numeric; serial_count integer; changed integer;
begin
 select * into p from public.products where id=p_product_id and business_id=p_business_id for update;
 if not found then raise exception 'A stock item no longer belongs to this store.'; end if;
 if not coalesce(p.track_inventory,false) or coalesce(p.item_type,'physical')<>'physical' then return; end if;
 if exists(select 1 from public.inventory_serials where business_id=p_business_id and product_id=p_product_id) then
  if p_quantity<>trunc(p_quantity) then raise exception 'Serial-tracked products must be sold in whole units.'; end if;
  select count(*) into serial_count from public.inventory_serials where business_id=p_business_id and product_id=p_product_id and status='in_stock';
  if serial_count<p_quantity then raise exception 'Not enough serialised units are available for %.',p.name; end if;
  update public.products set stock=stock-p_quantity where id=p_product_id and business_id=p_business_id and stock>=p_quantity;
  if not found then raise exception 'Product stock changed. Please refresh your cart.'; end if;
  with chosen as (select id from public.inventory_serials where business_id=p_business_id and product_id=p_product_id and status='in_stock' order by created_at,id limit p_quantity::integer for update skip locked)
  update public.inventory_serials s set status='sold',store_order_id=p_order_id,store_order_item_id=p_order_item_id,sold_at=now() from chosen c where s.id=c.id;
  get diagnostics changed=row_count;
  if changed<>p_quantity then raise exception 'Serialised stock changed. Please refresh your cart.'; end if;
  insert into public.store_order_inventory_allocations(store_order_id,store_order_item_id,product_id,quantity,allocation_kind) values(p_order_id,p_order_item_id,p_product_id,p_quantity,'serial');
  return;
 end if;
 if exists(select 1 from public.inventory_batches where business_id=p_business_id and product_id=p_product_id) then
  update public.products set stock=stock-p_quantity where id=p_product_id and business_id=p_business_id and stock>=p_quantity;
  if not found then raise exception 'Product stock changed. Please refresh your cart.'; end if;
  remaining:=p_quantity;
  for batch in select * from public.inventory_batches where business_id=p_business_id and product_id=p_product_id and quantity>0 and (expires_at is null or expires_at>=current_date) order by expires_at nulls last,received_at nulls first,created_at for update loop
   take_qty:=least(remaining,batch.quantity);
   update public.inventory_batches set quantity=quantity-take_qty where id=batch.id and quantity>=take_qty;
   if not found then raise exception 'Inventory batch changed. Please retry checkout.'; end if;
   insert into public.store_order_inventory_allocations(store_order_id,store_order_item_id,product_id,batch_id,quantity,allocation_kind) values(p_order_id,p_order_item_id,p_product_id,batch.id,take_qty,'batch');
   remaining:=remaining-take_qty; exit when remaining<=0;
  end loop;
  if remaining>0 then raise exception 'Not enough unexpired batch stock is available for %.',p.name; end if;
  return;
 end if;
 update public.products set stock=stock-p_quantity where id=p_product_id and business_id=p_business_id and stock>=p_quantity;
 if not found then raise exception 'Product stock changed. Please refresh your cart.'; end if;
 insert into public.store_order_inventory_allocations(store_order_id,store_order_item_id,product_id,quantity,allocation_kind) values(p_order_id,p_order_item_id,p_product_id,p_quantity,'product');
end $$;
revoke all on function public.reserve_orderdesk_product_inventory(uuid,uuid,numeric,uuid,uuid) from public;

create or replace function public.restore_orderdesk_catalog_stock_on_status_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare a record; has_allocations boolean; chosen_count integer; q numeric;
begin
 if tg_op<>'UPDATE' then return new; end if;
 select exists(select 1 from public.store_order_inventory_allocations where store_order_id=new.id) into has_allocations;
 if new.status='Cancelled' and old.status<>'Cancelled' then
  if has_allocations then
   for a in select * from public.store_order_inventory_allocations where store_order_id=new.id loop
    if a.allocation_kind='variant' and a.variant_id is not null then update public.catalog_variants set stock=stock+a.quantity where id=a.variant_id;
    elsif a.allocation_kind='batch' and a.batch_id is not null then update public.inventory_batches set quantity=quantity+a.quantity where id=a.batch_id; update public.products set stock=stock+a.quantity where id=a.product_id;
    elsif a.allocation_kind='serial' then update public.products set stock=stock+a.quantity where id=a.product_id; update public.inventory_serials set status='in_stock',store_order_id=null,store_order_item_id=null,sold_at=null where store_order_id=new.id and store_order_item_id=a.store_order_item_id and status='sold';
    else update public.products set stock=stock+a.quantity where id=a.product_id;
    end if;
   end loop;
  else
   for a in select i.product_id,i.quantity from public.store_order_items i join public.products p on p.id=i.product_id where i.store_order_id=new.id and i.product_id is not null and coalesce(i.item_type,'physical')='physical' and p.track_inventory and not coalesce(p.is_bundle,false) and i.variant_id is null loop update public.products set stock=stock+a.quantity where id=a.product_id; end loop;
  end if;
 elsif old.status='Cancelled' and new.status<>'Cancelled' then
  if has_allocations then
   for a in select * from public.store_order_inventory_allocations where store_order_id=new.id loop
    if a.allocation_kind='variant' and a.variant_id is not null then update public.catalog_variants set stock=stock-a.quantity where id=a.variant_id and stock>=a.quantity;
    elsif a.allocation_kind='batch' and a.batch_id is not null then update public.inventory_batches set quantity=quantity-a.quantity where id=a.batch_id and quantity>=a.quantity and (expires_at is null or expires_at>=current_date); if not found then raise exception 'The original inventory batch is expired or no longer has enough stock to reopen this order.'; end if; update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity;
    elsif a.allocation_kind='serial' then
     update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity;
     if not found then raise exception 'Insufficient product stock to reopen this order.'; end if;
     q:=a.quantity;
     with chosen as (select id from public.inventory_serials where product_id=a.product_id and business_id=(select business_id from public.store_orders where id=new.id) and status='in_stock' order by created_at,id limit q::integer for update skip locked)
     update public.inventory_serials s set status='sold',store_order_id=new.id,store_order_item_id=a.store_order_item_id,sold_at=now() from chosen c where s.id=c.id;
     get diagnostics chosen_count=row_count;if chosen_count<>q then raise exception 'Not enough serialised units to reopen this order.'; end if;
    else update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity;
    end if;
    if not found then raise exception 'Insufficient stock to reopen this cancelled order.'; end if;
   end loop;
  else
   for a in select i.product_id,i.quantity from public.store_order_items i join public.products p on p.id=i.product_id where i.store_order_id=new.id and i.product_id is not null and coalesce(i.item_type,'physical')='physical' and p.track_inventory and not coalesce(p.is_bundle,false) and i.variant_id is null loop update public.products set stock=stock-a.quantity where id=a.product_id and stock>=a.quantity; if not found then raise exception 'Insufficient stock to reopen this cancelled order.'; end if; end loop;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists store_order_restore_catalog_stock on public.store_orders;
drop trigger if exists store_order_restore_stock on public.store_orders;
drop trigger if exists store_orders_stock_status on public.store_orders;
create trigger store_order_restore_catalog_stock after update of status on public.store_orders for each row execute function public.restore_orderdesk_catalog_stock_on_status_change();

-- Complete customer-facing checkout option validation and pricing for variants, add-ons and option groups.
create or replace function public.place_store_order_catalog(
 p_slug text,p_customer_name text,p_customer_phone text,p_customer_email text,p_delivery_address text,
 p_customer_note text,p_payment_method text,p_items jsonb,p_idempotency_key text,p_delivery_zone_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; z public.store_delivery_zones%rowtype; x jsonb; p public.products%rowtype; v public.catalog_variants%rowtype;
 q numeric; unit numeric(12,2); line numeric(12,2); sub numeric(12,2):=0; fee numeric(12,2):=0; oid uuid; ref text;
 mods jsonb; mod_ids uuid[]; option_ids uuid[]; option_snapshot jsonb; m record; mg record; og record; ov record; n integer; existing public.store_orders%rowtype; sku text; itype text; item_id uuid;
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
  if coalesce(p.is_bundle,false) and not exists(select 1 from public.catalog_bundle_items bi where bi.bundle_product_id=p.id and bi.business_id=b.id) then raise exception 'This bundle has no components configured.'; end if;
  if nullif(x->>'variant_id','') is not null then
   select * into v from public.catalog_variants where id=(x->>'variant_id')::uuid and product_id=p.id and business_id=b.id and is_active for update;
   if not found then raise exception 'A selected variation is no longer available.'; end if;
   unit:=coalesce(v.price,p.price); sku:=coalesce(v.sku,p.sku);
   if v.track_inventory and v.stock<q then raise exception 'Not enough stock for variation %.',v.label; end if;
  elsif p.track_inventory and p.stock<q and itype='physical' and not coalesce(p.is_bundle,false) then raise exception 'Not enough stock for %.',p.name; end if;
  mods:= '[]'::jsonb; mod_ids:=array(select jsonb_array_elements_text(coalesce(x->'modifier_ids','[]'::jsonb))::uuid);
  option_ids:=array(select jsonb_array_elements_text(coalesce(x->'option_value_ids','[]'::jsonb))::uuid);
  select count(*) into n from public.catalog_option_values ov join public.catalog_option_groups og on og.id=ov.group_id where ov.id=any(option_ids) and ov.business_id=b.id and og.business_id=b.id and og.product_id=p.id and ov.is_available;
  if n<>cardinality(option_ids) then raise exception 'A selected product option is no longer available.'; end if;
  for og in select * from public.catalog_option_groups where product_id=p.id and business_id=b.id loop
   select count(*) into n from public.catalog_option_values ov where ov.group_id=og.id and ov.business_id=b.id and ov.is_available and ov.id=any(option_ids);
   if (og.is_required and n=0) or (og.selection_mode='single' and n>1) then raise exception 'Please review selections for %.',og.name; end if;
  end loop;
  for mg in select * from public.catalog_modifier_groups where product_id=p.id and business_id=b.id loop
   select count(*) into n from public.catalog_modifiers mm where mm.group_id=mg.id and mm.is_available and mm.id=any(mod_ids);
   if n<mg.min_select or (mg.is_required and n=0) or n>mg.max_select then raise exception 'Please review selections for %.',mg.name; end if;
  end loop;
  for m in select mm.id,mm.name,mm.price,mm.group_id from public.catalog_modifiers mm join public.catalog_modifier_groups gg on gg.id=mm.group_id where gg.product_id=p.id and gg.business_id=b.id and mm.is_available and mm.id=any(mod_ids) loop
   unit:=unit+m.price; mods:=mods||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price));
  end loop;
  for ov in select ov.price_delta from public.catalog_option_values ov join public.catalog_option_groups og on og.id=ov.group_id where og.product_id=p.id and og.business_id=b.id and ov.business_id=b.id and ov.is_available and ov.id=any(option_ids) loop unit:=unit+ov.price_delta; end loop;
  sub:=sub+(unit*q);
 end loop;
 ref:='OD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.store_orders(business_id,order_ref,idempotency_key,customer_name,customer_phone,customer_email,delivery_address,customer_note,payment_method,payment_status,subtotal,delivery_fee,total,delivery_zone_name)
 values(b.id,ref,trim(p_idempotency_key),trim(p_customer_name),trim(p_customer_phone),nullif(trim(coalesce(p_customer_email,'')),''),trim(p_delivery_address),nullif(trim(coalesce(p_customer_note,'')),''),p_payment_method,case when p_payment_method in ('Bank transfer','Paystack') then 'Awaiting payment' else 'Pay on delivery' end,sub,fee,sub+fee,z.name) returning id into oid;
 -- Insert immutable line snapshots and reserve inventory in the same transaction.
 for x in select value from jsonb_array_elements(p_items) loop
  q:=(x->>'quantity')::numeric; select * into p from public.products where id=(x->>'product_id')::uuid and business_id=b.id and store_published for update;
  unit:=p.price; sku:=p.sku; mods:='[]'::jsonb; option_snapshot:='[]'::jsonb; mod_ids:=array(select jsonb_array_elements_text(coalesce(x->'modifier_ids','[]'::jsonb))::uuid); option_ids:=array(select jsonb_array_elements_text(coalesce(x->'option_value_ids','[]'::jsonb))::uuid);
  if nullif(x->>'variant_id','') is not null then select * into v from public.catalog_variants where id=(x->>'variant_id')::uuid and product_id=p.id and business_id=b.id and is_active for update; unit:=coalesce(v.price,p.price); sku:=coalesce(v.sku,p.sku); if v.track_inventory then update public.catalog_variants set stock=stock-q where id=v.id and stock>=q; if not found then raise exception 'Variation stock changed. Please refresh your cart.'; end if; insert into public.store_order_inventory_allocations(store_order_id,product_id,variant_id,quantity,allocation_kind) values(oid,p.id,v.id,q,'variant'); end if;
  elsif p.track_inventory and coalesce(p.item_type,'physical')='physical' and not coalesce(p.is_bundle,false) then null; end if;
  for m in select mm.id,mm.name,mm.price from public.catalog_modifiers mm join public.catalog_modifier_groups gg on gg.id=mm.group_id where gg.product_id=p.id and gg.business_id=b.id and mm.is_available and mm.id=any(mod_ids) loop unit:=unit+m.price; mods:=mods||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price)); end loop;
  for ov in select ov.id,ov.label,ov.price_delta,og.name as group_name from public.catalog_option_values ov join public.catalog_option_groups og on og.id=ov.group_id where og.product_id=p.id and og.business_id=b.id and ov.business_id=b.id and ov.is_available and ov.id=any(option_ids) loop unit:=unit+ov.price_delta; option_snapshot:=option_snapshot||jsonb_build_array(jsonb_build_object('id',ov.id,'group',ov.group_name,'label',ov.label,'price_delta',ov.price_delta)); end loop;
  insert into public.store_order_items(store_order_id,product_id,product_name,quantity,unit_price,line_total,item_type,variant_id,selected_options,modifiers_snapshot,sku_snapshot,fulfilment_method)
  values(oid,p.id,p.name,q,unit,unit*q,coalesce(p.item_type,'physical'),nullif(x->>'variant_id','')::uuid,coalesce(x->'selected_options','{}'::jsonb)||jsonb_build_object('options',option_snapshot),mods,sku,coalesce(x->>'fulfilment_method','delivery')) returning id into item_id;
  if nullif(x->>'variant_id','') is null and p.track_inventory and coalesce(p.item_type,'physical')='physical' and not coalesce(p.is_bundle,false) then perform public.reserve_orderdesk_product_inventory(b.id,p.id,q,oid,item_id); end if;
  if p.is_bundle then
   for m in select bi.component_product_id,bi.quantity*q as qty from public.catalog_bundle_items bi where bi.bundle_product_id=p.id and bi.business_id=b.id loop perform public.reserve_orderdesk_product_inventory(b.id,m.component_product_id,m.qty,oid,item_id); end loop;
  end if;
 end loop;
 return jsonb_build_object('order_id',oid,'order_ref',ref,'subtotal',sub,'delivery_fee',fee,'total',sub+fee,'payment_method',p_payment_method,'receipt_token',(select receipt_token from public.store_orders where id=oid),'bank_name',b.store_bank_name,'account_name',b.store_account_name,'account_number',b.store_account_number,'payment_note',b.store_payment_note);
end $$;


-- Platform-owned subscription transfer details; no account details are hardcoded in the app.
create or replace function public.get_orderdesk_subscription_payment_details()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare r public.platform_payment_settings%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in to view subscription payment instructions.'; end if;
 if not exists(select 1 from public.businesses where owner_id=auth.uid()) then raise exception 'Merchant account required.'; end if;
 select * into r from public.platform_payment_settings where id=1;
 return jsonb_build_object('enabled',coalesce(r.subscription_payment_enabled,false) and nullif(trim(r.subscription_bank_name),'') is not null and nullif(trim(r.subscription_account_name),'') is not null and length(regexp_replace(coalesce(r.subscription_account_number,''),'\D','','g'))=10,'bank_name',r.subscription_bank_name,'account_name',r.subscription_account_name,'account_number',r.subscription_account_number,'instructions',r.subscription_payment_instructions);
end $$;
revoke all on function public.get_orderdesk_subscription_payment_details() from public;
grant execute on function public.get_orderdesk_subscription_payment_details() to authenticated;
create or replace function public.owner_update_orderdesk_subscription_payment_details(p_bank_name text,p_account_name text,p_account_number text,p_instructions text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare acct text;
begin
 if auth.uid()<>'327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid then raise exception 'Not authorised.'; end if;
 acct:=regexp_replace(coalesce(p_account_number,''),'\D','','g');
 if coalesce(p_enabled,false) and (length(trim(coalesce(p_bank_name,'')))<2 or length(trim(coalesce(p_account_name,'')))<2 or length(acct)<>10) then raise exception 'Enter a bank name, account name and valid 10-digit account number before enabling payments.'; end if;
 update public.platform_payment_settings set subscription_bank_name=left(trim(coalesce(p_bank_name,'')),100),subscription_account_name=left(trim(coalesce(p_account_name,'')),120),subscription_account_number=acct,subscription_payment_instructions=left(trim(coalesce(p_instructions,'')),1000),subscription_payment_enabled=coalesce(p_enabled,false) where id=1;
 if not found then raise exception 'Platform payment settings row is missing.'; end if;
 return true;
end $$;
revoke all on function public.owner_update_orderdesk_subscription_payment_details(text,text,text,text,boolean) from public;
grant execute on function public.owner_update_orderdesk_subscription_payment_details(text,text,text,text,boolean) to authenticated;

commit;
