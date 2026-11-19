-- Run once in Supabase SQL Editor to enable the product unit selector.
ALTER TABLE public.products
ADD COLUMN IF NOT EXISTS unit text NOT NULL DEFAULT 'Pieces';
