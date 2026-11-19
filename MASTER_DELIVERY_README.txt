ORDERDESK NG — CONSOLIDATED PREMIUM UPGRADE PACKAGE
Company: TEMI DIGITAL SOLUTIONS
Source baseline: OrderDesk_NG_Store_Support_Upgrade (2).zip
Prepared: 10 November 2026

WHAT THIS PACKAGE IS
This is the consolidated working project package containing the supplied OrderDesk NG application plus the verified Phase 2 premium interface/onboarding changes. It is intended to be the single working ZIP for the next development and test cycle.

IMPLEMENTED IN THIS PACKAGE
1. Premium dark emerald glassmorphism visual system across the merchant app, storefront and owner console.
2. Responsive visual treatments for navigation, panels, forms, tables, modals and mobile layouts.
3. First-run six-step onboarding with progress saving and business-scoped storage migration.
4. OrderDesk Command Centre with action prompts derived from the signed-in workspace's existing orders, balances, customers and stock levels.
5. Reduced-motion accessibility treatment.
6. PWA theme and service-worker cache version updates.
7. Existing application source, SQL setup files, Netlify configuration/functions, storefront and admin console retained in the project.

IMPORTANT FEATURE STATUS
The following are product priorities and must not be represented as live merely because they appear in the master roadmap: AI Business Advisor, full profit/expense accounting, customer loyalty points, team invitations and granular roles, advanced multi-channel analytics, fraud detection, and a native Android app/APK. They require additional implementation, database design, provider configuration and end-to-end testing. The existing AI follow-up function is retained, but that is not equivalent to a complete AI business advisor.

PRODUCTION SAFETY
- No production deployment has been performed.
- No live Supabase SQL has been executed.
- No live OAuth, payment, receipt upload, checkout, RLS cross-business isolation or support ticket end-to-end test has been performed.
- Do not run migrations against production until a separate test Supabase project passes the test plan.
- Never place a Supabase service-role key or private payment credentials in browser code.
- Do not disable RLS to resolve access errors.
- Back up the current site and database before any deployment or migration.

RECOMMENDED TEST ORDER
1. Create a separate Supabase test project.
2. Review README.txt, UPDATE_NOTES.txt, ONLINE_STORE_README.txt and SUPPORT_UPGRADE_NOTES.txt.
3. Apply the existing baseline schema/migrations in their documented dependency order; then apply phase2_onboarding.sql.
4. Deploy to a Netlify preview site, not the production site.
5. Test email registration/login, Google OAuth callback, onboarding save/resume/skip, returning-user behaviour, and business ownership isolation.
6. Test products, stock changes, customers, orders, payments, online storefront, cart, checkout, receipt upload/review, tracking, support, admin permissions and PWA installation.
7. Test on desktop and Android browsers, including narrow screens and reduced-motion preference.
8. Review browser console, Netlify function logs and Supabase logs. Record all failures before production approval.

PACKAGE STRUCTURE
- index.html: merchant-facing application.
- shop.html: customer storefront.
- admin.html: owner/admin console.
- netlify/: serverless functions.
- *.sql: baseline and additive database scripts; inspect each script and follow dependency notes before applying.
- manifest.webmanifest, sw.js, icon files: PWA assets.
- PHASE2_IMPLEMENTATION_REPORT.txt: scope and validation performed for Phase 2.
- MASTER_IMPLEMENTATION_STATUS.txt: consolidated status and remaining work.

This package is a development deliverable, not a claim that every roadmap item is complete or production-certified.
