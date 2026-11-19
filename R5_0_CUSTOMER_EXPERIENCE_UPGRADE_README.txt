ORDERDESK NG R5.0 — CUSTOMER EXPERIENCE & STORE UPGRADE
Review package | Built from R4.9.1 | 18 November 2026

WHAT IS INCLUDED
1. Existing R4.9.1 features retained: merchant AI assistant, public shopper AI assistant, store/product sharing, direct product links, SEO metadata, structured data, and dark green-glass product reviews.
2. Universal customer account page: /customer-account.html. Customers use one Supabase Auth identity across participating OrderDesk stores. Email magic-link sign-in; profile, default address, saved addresses, order history, and wishlist.
3. Guest checkout is retained. When a customer is signed in, new Online Store orders are linked to that customer account by a database trigger. Old guest orders are not automatically matched or migrated to customer accounts.
4. Merchant Dashboard adds Customers & Insights: online customer list, purchase counts, customer spend, returning-customer indicator, visitor/product-view/cart/checkout analytics and traffic sources.
5. Merchant Dashboard adds Feedback & Reviews: approve/hide product reviews, display verified-purchase indicator, reply to reviews, and manage general store feedback with status/replies.
6. Public shop adds customer account and feedback entry points, wishlist save action, and privacy-conscious store/product/cart/checkout analytics events.
7. Store Tools includes merchant-managed product-variation records and delivery-zone records.
8. New SQL migration is additive. It does not drop existing tables or modify subscription/payment records.

IMPORTANT IMPLEMENTATION LIMITS — READ BEFORE DEPLOYMENT
A. Product variations and delivery zones can currently be created and managed by the merchant, and a public options RPC is included. They are NOT yet connected to the public product selector, stock reservation, Paystack initialization, or checkout delivery-fee calculation. Do not tell customers these options are available until a separate checkout integration has been tested.
B. Customer accounts link new signed-in checkouts. Guest checkout still works. Historic guest orders are not auto-linked to accounts.
C. Verified purchase is set only when the signed-in account has a Delivered order containing that product. Guest reviews are not marked verified.
D. Visitor analytics records anonymous random browser-session IDs and event counts only. It does not track names, emails, phone numbers, form contents, or session replay. It is directional analytics, not a replacement for a full analytics platform.
E. Product reviews submitted after the migration are pending until a merchant approves them. Existing reviews are grandfathered as approved.
F. Email magic-link login requires Supabase Auth email delivery and the correct deployed redirect URL to be configured. Check Supabase Auth URL Configuration and email provider settings before rollout.
G. The account page and all new SQL functions have not been tested against the live OrderDesk Supabase project. Use a separate test project and test merchant/customer accounts first.

DATABASE SETUP
This migration depends on the existing OrderDesk NG schema, Online Store migration and R4.9 product-review migration being present.
Run ONLY in the OrderDesk NG Supabase project, never TEMI's separate project:
  r5_customer_experience_migration.sql

Do not run it in production until it has passed on a separate test Supabase project. It is additive, but it adds auth-linked customer profiles, customer addresses, wishlist, review moderation columns, customer feedback, analytics, product variants and delivery zones.

DEPLOYMENT CONTENT
Upload the contents of this ZIP to the existing Netlify site only after reviewing and testing. Keep a backup of the current deployment. Do not upload the ZIP itself as a nested file; extract it and upload the site files at the published root using the existing manual Netlify workflow.

REQUIRED TESTS BEFORE PRODUCTION
- Existing merchant login, Google login and dashboard navigation.
- Existing manual orders, payments, inventory, subscriptions and admin owner access.
- Existing public shop, SEO, sharing, checkout, receipt upload, Paystack and order notifications.
- Customer magic-link sign-in, sign-out, profile save, address add/remove, wishlist, and order history across two test shops.
- Signed-in checkout links order to customer_user_id; guest checkout remains unaffected.
- Review submission remains pending, merchant approval publishes it, hide removes it, reply displays correctly, and only eligible signed-in delivered purchases receive Verified Purchase.
- Public feedback reaches only the correct merchant; replies and status updates work.
- Analytics counts store views, product views, add-to-cart and checkout starts without collecting personal data.
- Confirm variant and delivery-zone data are not used in checkout yet; flat delivery fee and current product stock logic must remain unchanged.
- Mobile UI: all new panels, inputs, cards and modals use the existing dark translucent emerald green-glass styling. No white review cards or white form panels.

NO PRODUCTION ACTIONS HAVE BEEN TAKEN
No live Netlify deployment, Supabase SQL execution, production data change, or environment-variable change was performed while preparing this review ZIP.


R5.0.1 PATCH — 18 November 2026
- Merchant desktop sidebar now has its own vertical scroll area; the mobile bottom menu has touch-friendly horizontal scrolling and a visible scrollbar where supported.
- Customer account page no longer links to the merchant app. When opened from a shop, it shows a safe Back to store link to that exact shop. The shop slug is preserved through the email sign-in callback.
- Merchant AI can read more of the signed-in merchant's workspace: product catalogue and photo availability, orders and order items, customers (without contact details), payments and sales summaries, store analytics, reviews, general feedback, support requests, public store settings, subscription status, product variations and delivery zones.
- For product-photo questions, up to three matching product images are sent to Groq's vision-capable Qwen model. Regular questions continue using the existing GROQ_HELP_MODEL/default text model. Optional GROQ_VISION_MODEL can override qwen/qwen3.8-27b; it is not required.
- AI access remains merchant-scoped via the signed-in JWT and existing Supabase RLS. The assistant does not receive bank account numbers, secret keys, payment references, receipts, customer phone numbers, customer email addresses or delivery addresses. Changes still require explicit merchant confirmation.
- No new SQL migration or environment variable is required. Existing GROQ_CHATBOT_API_KEY remains required. Vision requests use additional Groq model usage and may have separate rate limits/costs.
- This is a code-level patch only; no live Supabase, Netlify or production data was changed.
