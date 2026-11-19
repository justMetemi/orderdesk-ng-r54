-- OrderDesk NG: add selected bank code for secure Paystack account-name resolution.
-- Run once in Supabase SQL Editor after online_store_upgrade.sql.
-- This is additive: it does not change existing orders, payments, products or customers.
begin;
alter table public.businesses add column if not exists store_bank_code text;
grant update(store_bank_code) on public.businesses to authenticated;
commit;
