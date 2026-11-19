-- OrderDesk NG, part 2. Run AFTER schema.sql: SQL Editor > New query > paste > Run (once).
alter table businesses add column if not exists address text, add column if not exists logo_url text, add column if not exists currency text not null default 'NGN', add column if not exists notify jsonb not null default '{"stock":true,"orders":true,"deliveries":true,"payments":true}', add column if not exists plan text not null default 'free', add column if not exists trial_ends timestamptz not null default now()+interval '14 days';
-- Customers can edit their profile but never their own plan or trial dates.
revoke update, insert on businesses from authenticated, anon;
grant update(name,owner_name,phone,email,address,logo_url,currency,notify) on businesses to authenticated;
grant insert(name,owner_name,phone,email) on businesses to authenticated;
create table products(id uuid primary key default gen_random_uuid(), business_id uuid not null default my_business() references businesses on delete cascade, name text not null, description text, category text, price numeric not null default 0 check(price>=0), stock numeric not null default 0, low_stock numeric not null default 5, image_url text, created_at timestamptz default now());
alter table orders add column if not exists product_id uuid references products on delete set null, add column if not exists stock_deducted boolean not null default false;
-- Stock is reduced once when an order becomes Delivered, and restored if it later moves back or is cancelled.
create function sync_stock() returns trigger language plpgsql as $$ begin
 if new.product_id is not null then
  if new.status='Delivered' and not new.stock_deducted then update products set stock=stock-new.quantity where id=new.product_id; new.stock_deducted:=true;
  elsif new.status<>'Delivered' and new.stock_deducted then update products set stock=stock+old.quantity where id=new.product_id; new.stock_deducted:=false; end if;
 end if; return new; end $$;
create trigger orders_stock before insert or update on orders for each row execute function sync_stock();
-- Subscriptions are written by the server after a real Paystack payment (not by the browser).
create table subscriptions(id uuid primary key default gen_random_uuid(), business_id uuid not null references businesses on delete cascade, plan text not null, status text not null, reference text, started_at timestamptz default now(), ends_at timestamptz);
alter table products enable row level security; alter table subscriptions enable row level security;
create policy own on products for all using(business_id=my_business()) with check(business_id=my_business());
create policy own_read on subscriptions for select using(business_id=my_business());
-- Storage for logos and product images (each user can only write inside their own folder).
insert into storage.buckets(id,name,public) values('logos','logos',true) on conflict do nothing;
create policy "logo read" on storage.objects for select using(bucket_id='logos');
create policy "logo insert" on storage.objects for insert to authenticated with check(bucket_id='logos' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "logo update" on storage.objects for update to authenticated using(bucket_id='logos' and (storage.foldername(name))[1]=auth.uid()::text);
