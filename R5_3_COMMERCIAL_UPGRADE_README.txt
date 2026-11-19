ORDERDESK NG R5.3 — COMMERCIAL UPGRADE BUILD
============================================

BASELINE
--------
Built from the corrected R5.2.4 source package. Existing pages, assets, Netlify
functions and prior migrations are retained. The R5.3 work is additive; it does
not delete merchant, customer, order, product or payment records.

WHAT IS INCLUDED IN THIS BUILD
------------------------------
1. Commercial plans
   - Free: core manual products, customers and orders; one-time starter AI quota.
   - Essentials: NGN 10,000 per month; online store, products, orders, customers,
     basic reporting and AI assistant.
   - Standard: NGN 15,000 per month; Essentials plus advanced catalogue tools,
     variants, option groups, add-ons, bundles, batch/serial stock, advanced
     insights and AI Product Studio.
   - Prepaid totals: Essentials 1m 10,000; 3m 28,500; 6m 54,000; 12m 102,000.
     Standard 1m 15,000; 3m 42,750; 6m 81,000; 12m 153,000.
   - New payment requests are manually reviewed by the platform owner. An
     approved next subscription starts after the current paid period ends.
   - Payment account details are configured in Admin; no bank account is
     hardcoded in the source. Payments remain disabled until the owner enables
     valid account details.

2. AI allowance and provider controls
   - Groq assistant is available on all plans with initial editable allowances:
     Free 20 messages once (does not renew without payment), Essentials 200
     messages per covered paid month, Standard 800 messages per covered paid
     month.
   - Cloudflare Workers AI image generation is Standard-only, initially 30 image credits per
     covered paid month. Free and Essentials image quota is fixed at zero.
   - No rollover. Prepaid 3/6/12-month subscriptions receive one allowance at
     each monthly anniversary covered by the payment. Expired or pending plans
     do not create a new paid allowance.
   - 75% and 90% usage notices, atomic reservation/commit/refund, and dashboard
     usage display are included. Provider failures restore the reserved credit.
   - The owner can adjust AI quotas in Admin. Quotas count assistant requests
     and generated images, not tokens.

3. Marketplace and customer account
   - Public marketplace search for published products in eligible active stores.
   - Product detail overlay and correct Visit Store links.
   - Customer Google sign-in and separate customer auth storage, shared between
     the customer portal and public store pages. Merchant authentication remains
     separate.
   - Unified customer order history, wishlist, addresses, followed stores,
     service bookings and confirmed digital purchases.
   - Customer account includes itemised order summaries and print/save-PDF.

4. Universal online checkout and inventory
   - Store checkout now displays and validates required option groups and
     selected option price deltas, modifiers/add-ons, variants and delivery zones.
   - Delivery zone fee is recalculated in the UI and independently resolved by
     the server-side checkout RPC.
   - Checkout allocates tracked physical stock using FEFO batches or serial
     numbers where those records exist. Order cancellation restores stock and
     serial state; reopening re-reserves stock and fails if the original batch or
     serial stock is no longer available.
   - Bundle components use the same tracked stock allocator.
   - Service appointment and paid digital fulfilment foundations are preserved.

5. Merchant and admin experience
   - Standard-only Store Tools, advanced insights and Growth Studio are gated in
     the interface and by database RLS/entitlement checks.
   - Admin can review commercial subscription payment requests, approve/reject,
     configure AI quotas and configure official subscription transfer details.
   - Daily email reminder function for 7, 3, 1 and 0 days before expiry.

6. Offline and downloads
   - Existing manual-order offline queue is preserved and now retries on the
     browser online event. The PWA install prompt and service worker are retained.
   - Inventory CSV export, report CSV export, order summaries and browser
     print/save-PDF for receipts/reports are included.
   - Browser print/save-PDF is used; this build does not add a server-side PDF
     rendering service or native Excel export.

DATABASE MIGRATION
------------------
New migration: r5_3_commercial_upgrade.sql

Prerequisites: the live database must already contain the existing OrderDesk
base schema, customer experience migration, R5.1 universal business catalogue,
R5.2 universal catalogue checkout, R5.2.2 service/digital fulfilment, and the
Paystack marketplace commission migration (which creates
platform_payment_settings). Do not rerun any migration already applied.

Recommended order in a separate test Supabase project:
1. Confirm the existing schema and R5.1/R5.2/R5.2.2/Paystack migrations are
   already applied.
2. Back up the database.
3. Run r5_3_commercial_upgrade.sql once.
4. Stop on the first SQL error and preserve the full error text.
5. Complete R5_3_RELEASE_TEST_CHECKLIST.txt before considering production.

The migration includes the corrected R5.2 checkout function, delivery-zone
column compatibility, option-group price validation, batch/serial allocations,
subscription tables/RPCs, AI usage ledger, marketplace RPC, customer account
extensions and private receipt storage policies.

NETLIFY ENVIRONMENT VARIABLES
-----------------------------
Keep all secrets in Netlify Environment Variables. Never place them in HTML or
send them in chat.

Required for existing merchant AI:
- GROQ_CHATBOT_API_KEY
- SUPABASE_URL
- SUPABASE_ANON_KEY

Cloudflare Workers AI Product Studio (image generation and reference editing):
- CLOUDFLARE_ACCOUNT_ID
- CLOUDFLARE_API_TOKEN (server-side only; grant Workers AI Read permission)
- Model is pinned in the function to @cf/black-forest-labs/flux-2-klein-4b. No model variable is required.
- No Gemini API key or paid-image enable switch is used. Cloudflare Workers Free currently includes 10,000 Neurons per day; requests fail after the free daily allowance is exhausted. Keep the account on Workers Free and monitor usage.

Required for Cloudinary image storage from Product Studio:
- CLOUDINARY_CLOUD_NAME
- CLOUDINARY_API_KEY
- CLOUDINARY_API_SECRET (server-side only; never put this in HTML or share it in chat)

Required for scheduled subscription email reminders:
- SUPABASE_URL
- SUPABASE_SERVICE_ROLE_KEY
- BREVO_API_KEY
- BREVO_SENDER_EMAIL
- BREVO_SENDER_NAME (optional)

The Supabase service-role key is server-only. Do not put it in index.html,
shop.html, marketplace.html, customer-account.html or any browser code.

This build adds Netlify Functions. After deployment, verify cloudflare-image and
subscription-reminders appear in the Netlify Functions tab. A static-only drag/drop
deploy may not bundle serverless functions; if they do not appear, use a Netlify
deploy workflow that processes netlify/functions and netlify.toml (for example,
a connected Git deploy). The scheduled reminder runs only on published deploys.

SUPABASE / GOOGLE AUTH SETTINGS
-------------------------------
- Enable Google as an Auth provider in the existing Supabase project.
- Add the deployed customer-account URL to Supabase Auth redirect allow-list,
  e.g. https://YOUR-ORDERDESK-DOMAIN/customer-account.html.
- Confirm the existing Supabase Google OAuth callback URI remains configured
  in Google Cloud.

ADMIN SETUP AFTER MIGRATION
---------------------------
1. Sign in as the platform owner and open Admin.
2. Enter the official OrderDesk subscription bank name, account name and
   10-digit account number under “OrderDesk subscription payment details”.
3. Verify the details independently, then enable subscription transfers.
4. Review the initial AI quotas and adjust if provider costs or capacity require.
5. Configure Netlify environment variables listed above and redeploy only after
   the test checklist passes.
6. Set up/verify the Brevo sender identity before expecting reminder emails.

CLOUDFLARE FREE-TIER NOTE
-------------------------
The Product Studio uses Cloudflare Workers AI with the FLUX.2 Klein 4B model for image generation and reference-image editing. Cloudflare currently provides 10,000 Neurons per day on the Workers Free plan. The daily allocation resets at 00:00 UTC; requests beyond the free allocation fail on Free rather than being billed. Keep the account on Workers Free and check Cloudflare's current model availability and usage dashboard before launch.
Official pricing: https://developers.cloudflare.com/workers-ai/platform/pricing/
Model documentation: https://developers.cloudflare.com/workers-ai/models/flux-2-klein-4b/


VALIDATION LIMITS
-----------------
JavaScript syntax and ZIP integrity can be checked locally. This environment
has no connection to the user's Supabase database, Netlify account, Paystack
account, Groq key, Cloudflare API token or Brevo account. Therefore this build has NOT had
PostgreSQL execution, browser end-to-end, payment, email, mobile-device or
cross-business security tests. Do not call it production-certified until the
separate test checklist is completed.
