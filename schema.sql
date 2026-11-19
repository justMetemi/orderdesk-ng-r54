-- OrderDesk NG database. In Supabase: SQL Editor > New query > paste all of this > Run (once).
create table businesses(id uuid primary key default gen_random_uuid(), owner_id uuid not null unique default auth.uid() references auth.users on delete cascade, name text not null, owner_name text, phone text, email text, created_at timestamptz default now());
create function my_business() returns uuid language sql stable security definer set search_path=public as $$ select id from businesses where owner_id=auth.uid() $$;
create table customers(id uuid primary key default gen_random_uuid(), business_id uuid not null default my_business() references businesses on delete cascade, name text not null, phone text not null, email text, address text, notes text, created_at timestamptz default now());
create table orders(id uuid primary key default gen_random_uuid(), order_no bigint generated always as identity, business_id uuid not null default my_business() references businesses on delete cascade, customer_id uuid not null references customers on delete cascade, product text not null, quantity numeric not null check(quantity>0), unit_price numeric not null check(unit_price>=0), total_amount numeric generated always as (quantity*unit_price) stored, amount_paid numeric not null default 0, status text not null default 'Pending' check(status in('Pending','Processing','Ready for Delivery','Delivered','Cancelled')), order_date date not null default current_date, delivery_date date, notes text, created_at timestamptz default now());
create table payments(id uuid primary key default gen_random_uuid(), business_id uuid not null default my_business() references businesses on delete cascade, order_id uuid not null references orders on delete cascade, amount numeric not null check(amount>0), method text not null check(method in('Bank transfer','Cash','POS','Other')), paid_at timestamptz default now());
create function add_payment() returns trigger language plpgsql as $$ begin update orders set amount_paid=amount_paid+new.amount where id=new.order_id; return new; end $$;
create trigger payment_added after insert on payments for each row execute function add_payment();
alter table businesses enable row level security;
create policy own on businesses for all using(owner_id=auth.uid()) with check(owner_id=auth.uid());
do $$ declare t text; begin foreach t in array array['customers','orders','payments'] loop
  execute format('alter table %I enable row level security',t);
  execute format('create policy own on %I for all using(business_id=my_business()) with check(business_id=my_business())',t);
end loop; end $$;
