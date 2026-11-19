ORDERDESK NG — PAYSTACK CHECKOUT + 5% PLATFORM COMMISSION
Package: OrderDesk_NG_Paystack_5_Percent_Upgrade.zip
Base: OrderDesk_NG_Shop_Index_Bank_Upgrade_Rev3.zip

WHAT THIS UPDATE ADDS
- Paystack online checkout alongside existing Bank transfer and Pay on delivery options.
- A server-side Paystack subaccount for each seller, created only after the seller's saved bank details are re-resolved through Paystack.
- 5% of each successful Paystack shop order product subtotal (excluding delivery fee) is split to the OrderDesk NG platform Paystack account; the seller receives the remaining product amount plus the delivery fee, before applicable Paystack transaction fees.
- Paystack transaction fees are assigned to the seller subaccount (bearer=subaccount), so they do not reduce the platform's 5% split.
- Server-side transaction verification on the return page and signed Paystack webhook handling. The browser redirect alone never marks an order as paid.
- A private platform_commissions ledger. Paystack split commissions are recorded as Collected. Bank-transfer commissions are recorded as Due when the seller confirms the receipt. Pay-on-delivery commissions are recorded as Due when the seller marks the order Delivered.
- Commission rate is stored in platform_payment_settings and starts at 5.00 percent.
- Existing dashboard, login, Supabase authentication, subscriptions, products, manual orders, customer records, bank-transfer checkout and pay-on-delivery checkout are retained.

IMPORTANT COMMISSION RULE
The 5% platform commission is calculated on the product subtotal only; delivery fees are excluded. The integration passes Paystack transaction_charge in kobo to collect that exact amount into the platform account, overriding the subaccount percentage split for the transaction. For direct bank transfer and pay-on-delivery, the 5% amount is only recorded as Due; it is not automatically removed from money the seller receives directly.

REQUIRED SETUP BEFORE DEPLOYMENT
1. Back up the current Supabase database and current deployed Netlify site.
2. In Supabase SQL Editor, run paystack_marketplace_commission_migration.sql AFTER the existing online_store_upgrade.sql and online_store_support_upgrade.sql migrations. This new migration also ensures store_bank_code and the account-verification fields exist. Do not rerun the original schema files.
3. In Netlify Site configuration > Environment variables, ensure PAYSTACK_SECRET_KEY exists and add SUPABASE_SERVICE_ROLE_KEY using the service_role/secret key from the same Supabase project. Keep both secret keys server-side only. Do not paste either key into index.html or shop.html.
4. SUPABASE_URL is optional in this package because the existing OrderDesk NG Supabase project URL is the fallback. If setting it, use the URL for the same Supabase project.
5. Deploy the full contents of this ZIP to the existing Netlify site (the ZIP has index.html and shop.html at its root). Do not deploy only the functions folder.
6. In Paystack Dashboard > Settings/API or Webhooks, set the webhook URL to:
   https://orderdeskng.netlify.app/.netlify/functions/paystack-webhook
7. Start with Paystack TEST keys and test transactions before switching to live keys.

SELLER BANK SETUP
The seller must select a supported bank from the bank dropdown, enter the 10-digit account number, click Verify account name, and save store settings. The current database output showed some merchants with store_bank_code = NULL. Those merchants must reselect/verify/save their bank details before Paystack checkout appears for their shop. Bank transfer and Pay on delivery remain available.

HOW THE PAYMENT FLOW WORKS
1. Customer selects Pay online with Paystack and enters an email address.
2. Netlify validates the seller bank details with Paystack and creates/reuses the seller subaccount with a 5% platform share.
3. The existing atomic Supabase place_store_order RPC validates products, prices, stock and idempotency, then creates the order with payment_method='Paystack'.
4. Netlify initializes Paystack checkout with the order's exact amount and seller subaccount.
5. Paystack sends the customer back to the shop. The server verifies the reference, amount, currency, order metadata and settlement subaccount before marking the order Confirmed.
6. The signed webhook performs the same verification as a reliable backup and the platform commission ledger records the split as Collected.

MANUAL PAYMENT COMMISSION
- Bank transfer: once the seller confirms the uploaded receipt, a 5% commission liability is recorded as Due.
- Pay on delivery: once the seller marks the order Delivered, a 5% commission liability is recorded as Due.
- No automatic deduction is possible from a transfer sent directly to a seller's own bank account. The platform must collect these Due amounts separately or reconcile them periodically.

COMMISSION SETTING
The initial rate is stored in public.platform_payment_settings (id=1, commission_percent=5.00). It is not exposed to merchant users. If the platform administrator changes the rate through a controlled server-side/admin process, newly created or refreshed seller subaccounts will use the new rate. Existing seller subaccounts are refreshed automatically on the next Paystack checkout when their stored commission snapshot differs.

BASIC TEST CHECKLIST
- Existing sign-in and dashboard still load.
- Existing bank-transfer checkout still creates an order and receipt upload still works.
- Existing pay-on-delivery checkout still creates an order.
- A seller with a saved bank code and matching account details sees Pay online with Paystack.
- A seller with store_bank_code NULL does not see Paystack checkout; existing payment options remain.
- Test payment succeeds, Paystack returns to the correct shop, and order tracking shows payment Confirmed.
- Webhook is accepted only with a valid x-paystack-signature.
- Wrong amount, currency, reference, metadata or settlement account does not mark the order paid.
- Repeated verification/webhook delivery does not create duplicate commission rows.
- Bank-transfer confirmation and delivered pay-on-delivery orders create Due commission ledger rows.
- Cancelled orders are not marked paid by a successful browser return.

SECURITY / RELEASE NOTES
- Do not expose PAYSTACK_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY to the browser.
- The Netlify initialization endpoint is public by design for customer checkout, but it uses service-role access only server-side and creates orders through the existing database checkout RPC, which rechecks the shop, subscription access, prices and stock.
- The callback URL is supplied per transaction; the webhook URL must still be configured in Paystack.
- This package has been statically checked, but it has not been connected to the user's live Paystack account or Supabase database. Complete the test checklist in Paystack test mode before live payments.
