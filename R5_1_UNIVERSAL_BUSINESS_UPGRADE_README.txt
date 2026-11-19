ORDERDESK NG R5.1 — UNIVERSAL BUSINESS UPGRADE FOUNDATION
Review package · Not deployed · No live database changes made

WHAT THIS PACKAGE ADDS
1. Business-neutral catalogue item types: physical, service, digital and custom.
2. Merchant-defined option groups and values. The data model does not hard-code sizes, colours, flavours, storage, materials or other category-specific choices.
3. Variant combinations with independent SKU/barcode, optional price, stock, image and active status.
4. Optional modifier/add-on groups for extras, accessories, toppings, service add-ons and similar choices.
5. Optional inventory batches, expiry dates, cost-per-unit and serial-number tracking.
6. Bundle composition using existing products.
7. Service appointment records with requested/confirmed/completed/cancelled/no-show states.
8. Order-line snapshot columns reserved for selected options, modifiers, SKU, item type and fulfilment method.
9. Private owner-console aggregate metrics for catalogue adoption and usage. It exposes counts only, not merchant/customer records.
10. Cross-business reference checks and owner-scoped RLS for new catalogue tables.

IMPORTANT IMPLEMENTATION BOUNDARY
This is the additive R5.1 database foundation and owner-admin visibility layer. It does NOT yet activate variant selection, modifier pricing, service booking checkout, digital delivery, batch/serial stock deduction, bundle stock calculation or delivery-zone pricing in the public storefront. Existing checkout, Paystack, bank-transfer receipt upload and order status logic are intentionally left unchanged. The added order snapshot columns are dormant until a separately validated checkout integration is enabled.

WHY THIS BOUNDARY MATTERS
The current public checkout uses one product_id and quantity per cart line and its database RPC prices/deducts stock from products.stock. Replacing that path without validating the Paystack initialization/verification/webhook and cancellation flows could cause incorrect totals or inventory. This package does not pretend those integrations are complete.

SAFE INSTALL / REVIEW ORDER
1. Back up the TEST Supabase project.
2. Apply the existing R5.0/R5.0.1 migrations there first, if not already applied.
3. Review and run r5_1_universal_business_upgrade.sql in the TEST project only.
4. Open admin.html using the authorised platform-owner account. The Universal business catalogue panel should show aggregate counts. If it reports that the migration is unavailable, check the SQL execution result and owner_is_admin() permissions.
5. Test that one merchant can create/read only its own rows in each new catalogue table. Try a deliberately mismatched product/group UUID and confirm the database rejects it.
6. Confirm all existing R5.0.1 flows still work: sign-in, products, manual orders, public shop, checkout, Paystack, bank-transfer receipt upload/review, order cancellation/restock, customer account, support and AI.

NOT INCLUDED / NOT TO BE CLAIMED AS LIVE
- No customer-facing variant/modifier selector.
- No variant-aware or modifier-aware order pricing/stock deduction.
- No service booking calendar or payment flow.
- No automated digital delivery.
- No batch/serial-aware stock ledger.
- No bundle stock reservation.
- No new admin actions that mutate merchant catalogues.

DEPLOYMENT SAFETY
Do not run the migration on production or upload this package to the live Netlify site until the owner has reviewed and approved it. No production changes were made by preparing this ZIP.
