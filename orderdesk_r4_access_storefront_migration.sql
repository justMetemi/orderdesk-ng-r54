-- OrderDesk NG R4: subscription access and public storefront refinement
-- Additive migration. Review and run in Supabase SQL Editor only after taking a database backup.
-- This migration does not alter existing customer/order/product rows.

create or replace function public.has_orderdesk_access_for_business(p_business_id uuid)
returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1
    from public.businesses b
    where b.id=p_business_id
      and (
        b.owner_id='327738f9-ad95-4b8e-89c7-6a4847fa1a63'::uuid
        or (coalesce(b.plan,'free')='free' and b.trial_ends is not null and b.trial_ends>now())
        or exists(
          select 1 from public.subscriptions s
          where s.business_id=b.id
            and lower(coalesce(s.status,''))='active'
            and s.ends_at>now()
        )
      )
  )
$$;

create or replace function public.get_public_shop(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
  select * into b from public.businesses
  where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found then return null; end if;
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

-- IMPORTANT:
-- Existing place_store_order(...) already checks has_orderdesk_access_for_business(...)
-- before creating an order. Keep that check in place. The Netlify Paystack
-- initializer is also updated in this package to enforce the same rule server-side.
-- Public get_public_shop intentionally returns the same business/products JSON
-- shape as the previous support migration, without exposing private merchant records.
