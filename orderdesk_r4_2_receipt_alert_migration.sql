-- OrderDesk NG R4.2: allow an idempotent WhatsApp alert when a bank-transfer receipt is submitted.
-- Review and run in Supabase SQL Editor after online_store_reporting_notifications_upgrade.sql.
-- This only expands the event_type constraint; it does not send messages by itself.
begin;
alter table public.store_order_notification_logs
  drop constraint if exists store_order_notification_logs_event_type_check;
alter table public.store_order_notification_logs
  add constraint store_order_notification_logs_event_type_check
  check (event_type in ('new_order','payment_success','receipt_submitted'));
-- Return the opaque order UUID to the customer tracking session so the receipt-upload
-- completion can request a merchant alert. The customer still cannot read the private
-- receipt path or delivery address through this public tracking RPC.
create or replace function public.track_store_order(p_order_ref text,p_phone text)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'id',so.id,'order_ref',so.order_ref,'business_name',coalesce(b.shop_name,b.name),'status',so.status,
    'payment_status',so.payment_status,'payment_method',so.payment_method,'subtotal',so.subtotal,
    'delivery_fee',so.delivery_fee,'total',so.total,'created_at',so.created_at,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name,'quantity',i.quantity,'line_total',i.line_total)),'[]'::jsonb) from public.store_order_items i where i.store_order_id=so.id)
  )
  from public.store_orders so join public.businesses b on b.id=so.business_id
  where upper(so.order_ref)=upper(trim(p_order_ref))
    and regexp_replace(so.customer_phone,'[^0-9]','','g')=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g')
  limit 1
$$;
revoke execute on function public.track_store_order(text,text) from public;
grant execute on function public.track_store_order(text,text) to anon,authenticated;

commit;
