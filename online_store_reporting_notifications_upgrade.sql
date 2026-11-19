-- OrderDesk NG: combined online-order reporting + merchant WhatsApp alerts.
-- Additive migration. Run once in Supabase SQL Editor after the existing online-store and Paystack migrations.
begin;

alter table public.businesses
  add column if not exists store_notification_whatsapp text;

-- The merchant can set a separate number for private order alerts.
grant update(store_notification_whatsapp) on public.businesses to authenticated;

-- Private idempotency log for automated WhatsApp notifications.
create table if not exists public.store_order_notification_logs (
  id uuid primary key default gen_random_uuid(),
  store_order_id uuid not null references public.store_orders(id) on delete cascade,
  event_type text not null check (event_type in ('new_order','payment_success')),
  status text not null default 'sent' check (status in ('sent')),
  provider_message_id text,
  created_at timestamptz not null default now(),
  unique(store_order_id,event_type)
);
alter table public.store_order_notification_logs enable row level security;
revoke all on public.store_order_notification_logs from public, anon, authenticated;

commit;
