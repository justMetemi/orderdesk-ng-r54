-- ORDERDESK NG PHASE 2: first-run onboarding profiles
-- Additive only. Does not alter or delete existing business records.
-- Run AFTER schema.sql and schema2.sql in a TEST Supabase project first.

create table if not exists public.onboarding_profiles (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  current_step integer not null default 0 check (current_step between 0 and 5),
  answers jsonb not null default '{}'::jsonb,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.onboarding_profiles enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='onboarding_profiles' and policyname='onboarding_select_own') then
    create policy onboarding_select_own on public.onboarding_profiles for select to authenticated
      using (business_id = public.my_business() and owner_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='onboarding_profiles' and policyname='onboarding_insert_own') then
    create policy onboarding_insert_own on public.onboarding_profiles for insert to authenticated
      with check (business_id = public.my_business() and owner_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='onboarding_profiles' and policyname='onboarding_update_own') then
    create policy onboarding_update_own on public.onboarding_profiles for update to authenticated
      using (business_id = public.my_business() and owner_id = auth.uid())
      with check (business_id = public.my_business() and owner_id = auth.uid());
  end if;
end $$;

grant select, insert, update on public.onboarding_profiles to authenticated;
revoke all on public.onboarding_profiles from anon;
