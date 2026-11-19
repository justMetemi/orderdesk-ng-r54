-- OrderDesk NG R4.3: private, idempotent delivery log for Brevo email notifications.
-- Additive only. Review and run in a TEST Supabase project first; do not blindly rerun older migrations.
begin;
create table if not exists public.store_order_email_logs (
  id uuid primary key default gen_random_uuid(),
  store_order_id uuid not null references public.store_orders(id) on delete cascade,
  event_type text not null check (event_type in ('new_order','payment_success','receipt_submitted')),
  recipient_type text not null check (recipient_type in ('merchant','customer')),
  recipient_email text not null,
  status text not null default 'sent' check (status in ('sent')),
  provider_message_id text,
  created_at timestamptz not null default now(),
  unique(store_order_id,event_type,recipient_type)
);
alter table public.store_order_email_logs enable row level security;
revoke all on public.store_order_email_logs from public, anon, authenticated;
commit;
