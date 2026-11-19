ORDERDESK NG — ONLINE ORDER REPORTING + MERCHANT WHATSAPP ALERTS
Build: 2026-11-11 R4

WHAT THIS UPDATE CHANGES
1. Dashboard totals, sales chart, order counts, status counts and recent activity now include both manual orders and public online-store purchases.
2. Main Orders page now shows manual orders and a separate Online Store Orders table. Online orders remain in their original store_orders table; the app does not duplicate them into the manual orders table.
3. Reports now include online store orders in order counts, sales totals, outstanding balances, delivered/cancelled counts, sales charts and popular-product totals. Report CSV includes online order references and statuses.
4. The Online Store settings form has a separate Merchant order-alert WhatsApp number. This is not the public customer-support WhatsApp number.
5. New online orders can trigger a merchant WhatsApp template alert. Successful Paystack payments and merchant-confirmed bank-transfer receipts can trigger a payment-success alert. WhatsApp failures do not block customer checkout or payment confirmation.
6. Paystack payment confirmation is explicitly distinguished from actual bank settlement. Check Paystack's dashboard for the settlement/payout state; OrderDesk does not claim to have bank-credit confirmation.

DATABASE MIGRATION
Run online_store_reporting_notifications_upgrade.sql once in Supabase SQL Editor. It is additive: it adds the merchant alert number and a private notification log. It does not delete or rewrite orders, products, customers, payments or stock.

WHATSAPP CLOUD API CONFIGURATION (REQUIRED FOR AUTOMATIC ALERTS)
The WhatsApp notification code is included, but automatic sending is not active until a Meta WhatsApp Cloud API sender and approved templates are configured.
Add these Netlify environment variables (server-side only):
- WHATSAPP_ACCESS_TOKEN = permanent/system-user access token for your WhatsApp Business Cloud API app
- WHATSAPP_PHONE_NUMBER_ID = the sender Phone Number ID from Meta WhatsApp Manager
- WHATSAPP_NEW_ORDER_TEMPLATE = orderdesk_new_order (or your approved equivalent)
- WHATSAPP_PAYMENT_SUCCESS_TEMPLATE = orderdesk_payment_success (or your approved equivalent)
- WHATSAPP_TEMPLATE_LANGUAGE = en (or the exact approved language code)
- WHATSAPP_GRAPH_VERSION = v22.0 (optional; package default)

Create and get Meta approval for TWO WhatsApp message templates. Both templates must have five BODY text placeholders, in this exact order:
{{1}} Store/business name
{{2}} Order reference
{{3}} Customer name
{{4}} Order total
{{5}} Payment status

Suggested template copy:
New order: "New order for {{1}}. Order {{2}} from {{3}}. Total: {{4}}. Payment: {{5}}. Please open OrderDesk NG to process the order."
Payment success: "Payment update for {{1}}. Order {{2}} from {{3}}. Amount: {{4}}. Status: {{5}}. Please check the order and Paystack settlement dashboard as needed."

Each merchant should enter the phone number that should receive alerts in Online Store > Store Settings > Merchant order-alert WhatsApp, then save settings. Use international Nigerian format when possible (e.g. 2348012345678) or local 080... format; the function converts a leading 0 to 234.

DEPLOYMENT
1. Back up your current Netlify site and Supabase database.
2. Run the new SQL migration above.
3. Configure WhatsApp environment variables only after Meta Cloud API and approved templates are ready. Do not put access tokens in HTML or send them in chat.
4. Deploy the complete extracted package folder to the existing Netlify site, not just the functions directory.
5. Keep the existing Paystack webhook URL:
   https://orderdeskng.netlify.app/.netlify/functions/paystack-webhook
6. Test in Paystack Test Mode. Test manual bank transfer, Pay on delivery and Paystack checkout. Verify online orders appear in Dashboard, Orders and Reports. Confirm notifications only after the WhatsApp templates are approved and sender is active.

IMPORTANT LIMITATIONS
- Static code checks do not prove live Supabase, Netlify, Paystack or Meta credentials are valid. Run the test checklist against your own services.
- WhatsApp automatic alerts require Meta's approved template messages; simply entering a phone number is not enough.
- Paystack test payments do not transfer real funds. A successful payment event is not proof that a merchant bank account has been credited.
- Existing manual orders and public store orders remain in separate database tables to preserve data integrity; the merchant interface combines their totals and presents both sources clearly.
