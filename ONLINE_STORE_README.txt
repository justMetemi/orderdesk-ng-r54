OrderDesk NG — Online Store Upgrade

THIS PACKAGE IS AN ADDITIVE UPDATE TO YOUR EXISTING ORDERDESK NG APP.
It does not deploy anything and it does not run SQL against production.

Existing application preserved:
- Email/password registration and login
- Google authentication
- Supabase business isolation and existing records
- Dashboard, manual orders, customers, payments, products and reports
- Existing product stock management
- Existing trial/subscription and manual OPay approval flow
- AI assistant and Netlify function
- Separate admin.html platform console
- PWA manifest/service worker/offline behaviour

Online Store added:
- Unique shop slug and public /shop/<slug> URL
- Store name, description, logo/contact display, delivery fee and bank-transfer details
- Existing Products table reused; publish/hide products from the store
- Public product search/category filters/cart/checkout
- Bank transfer + receipt upload or Pay on delivery
- Secure database-priced checkout with atomic stock reservation and idempotency key
- Private receipt storage and owner-only signed receipt viewing
- Owner Online Orders management, payment receipt confirmation/rejection and status updates
- Customer tracking by order reference + phone
- Trial/subscription enforcement for public storefront access and new online orders

TEST ORDER
1. Create a separate Supabase TEST project.
2. Run schema.sql.
3. Run schema2.sql.
4. Run your existing subscription setup used by OrderDesk NG (the original source references subscription_payment_requests and its existing payment-approval functions; those definitions were not included in the pasted schema).
5. Run online_store_upgrade.sql, then online_store_support_upgrade.sql (storefront support, FAQs, discounts, enquiries, platform support).
6. Configure the test project URL/key in index.html, shop.html and admin.html as appropriate. Keep the existing public/publishable key; never put a service-role key in frontend files.
7. Open index.html through a local static server (not file://), create/sign into a test business, configure Online Store, publish products, then open the generated /shop/<slug> URL.
8. Test both payment methods, receipt upload/verification, cancellation/restocking, order tracking, duplicate checkout attempts, expired trial access and cross-business isolation.

STATIC TESTS TO PERFORM BEFORE DEPLOYMENT
- JavaScript syntax check: index.html inline JS, shop.html inline JS and the existing AI Netlify function.
- Existing admin.html, AI function, manifest and PWA assets were preserved; admin.html and AI function were not modified.
- Migration was checked to ensure it contains no DROP TABLE, DROP SCHEMA, TRUNCATE or production-deletion statements.

IMPORTANT
A live Supabase integration test was NOT performed because no separate test Supabase project was supplied and production must not be touched. Do not treat this package as production-verified until the TEST ORDER above has been completed.
