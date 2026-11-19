-- OrderDesk NG R4.9 — Public product ratings and customer feedback
-- Additive migration. Run in the OrderDesk NG Supabase project only.
-- Reviews are published immediately and can be submitted once per product/email.

begin;

create table if not exists public.store_product_reviews (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  reviewer_name text not null check (char_length(trim(reviewer_name)) between 2 and 60),
  reviewer_email text not null check (char_length(trim(reviewer_email)) between 5 and 254),
  rating smallint not null check (rating between 1 and 5),
  comment text not null check (char_length(trim(comment)) between 5 and 1000),
  created_at timestamptz not null default now(),
  unique (product_id, reviewer_email)
);

create index if not exists store_product_reviews_product_created_idx
  on public.store_product_reviews(product_id, created_at desc);

alter table public.store_product_reviews enable row level security;
revoke all on public.store_product_reviews from anon, authenticated;

create or replace function public.get_public_shop_reviews(p_slug text)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype; result jsonb;
begin
  select * into b from public.businesses
   where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id',x.product_id,'average',round(x.avg_rating::numeric,1),'count',x.review_count,
    'reviews',x.reviews
  )), '[]'::jsonb) into result
  from (
    select r.product_id, avg(r.rating)::numeric as avg_rating, count(*)::int as review_count,
      (select coalesce(jsonb_agg(jsonb_build_object('name',z.reviewer_name,'rating',z.rating,'comment',z.comment,'created_at',z.created_at) order by z.created_at desc),'[]'::jsonb)
       from (select reviewer_name,rating,comment,created_at from public.store_product_reviews
             where product_id=r.product_id order by created_at desc limit 10) z) as reviews
    from public.store_product_reviews r
    join public.products p on p.id=r.product_id and p.business_id=b.id and p.store_published=true
    where r.business_id=b.id
    group by r.product_id
  ) x;
  return result;
end $$;

create or replace function public.submit_public_product_review(
  p_slug text, p_product_id uuid, p_reviewer_name text, p_reviewer_email text,
  p_rating integer, p_comment text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
  select * into b from public.businesses
   where lower(shop_slug)=lower(trim(p_slug)) and store_enabled=true;
  if not found or not public.has_orderdesk_access_for_business(b.id) then raise exception 'This shop is unavailable.'; end if;
  if not exists(select 1 from public.products where id=p_product_id and business_id=b.id and store_published=true) then
    raise exception 'This product is not available for reviews.';
  end if;
  if char_length(trim(coalesce(p_reviewer_name,''))) not between 2 and 60 then raise exception 'Enter your name (2–60 characters).'; end if;
  if char_length(trim(coalesce(p_reviewer_email,''))) not between 5 and 254 or trim(p_reviewer_email) !~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then raise exception 'Enter a valid email address.'; end if;
  if p_rating not between 1 and 5 then raise exception 'Choose a rating from 1 to 5.'; end if;
  if char_length(trim(coalesce(p_comment,''))) not between 5 and 1000 then raise exception 'Feedback must be 5–1,000 characters.'; end if;
  insert into public.store_product_reviews(business_id,product_id,reviewer_name,reviewer_email,rating,comment)
  values(b.id,p_product_id,trim(p_reviewer_name),lower(trim(p_reviewer_email)),p_rating,trim(p_comment));
  return jsonb_build_object('success',true,'message','Thank you. Your review has been published.');
exception when unique_violation then
  raise exception 'You have already reviewed this product with that email address.';
end $$;

revoke all on function public.get_public_shop_reviews(text) from public;
revoke all on function public.submit_public_product_review(text,uuid,text,text,integer,text) from public;
grant execute on function public.get_public_shop_reviews(text) to anon, authenticated;
grant execute on function public.submit_public_product_review(text,uuid,text,text,integer,text) to anon, authenticated;

commit;
