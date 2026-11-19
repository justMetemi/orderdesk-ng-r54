ORDERDESK NG R4.8 — AI MERCHANT & SHOPPER ASSISTANTS
Review package. No production deployment or database changes were performed.

WHAT IS INCLUDED
1. Merchant AI Assistant (dashboard + merchant Online Store area)
   - Uses the existing GROQ_CHATBOT_API_KEY and GROQ_HELP_MODEL settings.
   - Authenticates the signed-in merchant through Supabase Auth.
   - Reads products, manual orders, online-store orders and customer counts through the merchant's own Supabase JWT. Existing row-level security remains the access boundary.
   - Can answer product/stock/order questions and prepare sales/stock summaries.
   - Can propose product creation, product edits, stock/price changes, discounts and order-status changes.
   - No mutation runs until the merchant clicks Confirm change in the assistant.
   - After an approved change, the dashboard reloads its data.

2. Public Shopper Assistant (public Online Store)
   - Separate assistant shown on the public shop page.
   - Receives only public storefront details and products already returned by get_public_shop.
   - Can help customers find products and understand public prices, availability, delivery and returns information.
   - Has no merchant login token and no mutation tools. It cannot read private orders, customer records, bank details or merchant settings.

SECURITY AND ACTION LIMITS
- No Supabase service-role key is used or sent to Groq.
- Merchant reads/writes use the signed-in merchant JWT and existing Supabase RLS.
- Customer phone numbers, delivery addresses, receipt files, payment credentials and bank details are not sent to Groq.
- Payment confirmation, refunds, subscription changes, bank-detail changes and deleting records are intentionally not available to the AI.
- Bank-transfer receipts must never be treated as proof of funds; merchants must verify their bank account independently.
- Approved actions are limited to product create/update/discount and manual/online order status updates.
- The AI can make mistakes. Review the proposed target and values before confirming.

CONFIGURATION
- Reuses GROQ_CHATBOT_API_KEY already configured in Netlify.
- Reuses GROQ_HELP_MODEL if set; otherwise openai/gpt-oss-20b is used.
- No new environment variable is required.
- No SQL migration is required for the R4.8 AI assistant features. R4.9 product reviews add a separate migration: orderdesk_product_reviews_migration.sql.

DEPLOYMENT NOTES
- Upload the extracted project contents / ZIP to the existing OrderDesk NG Netlify site only after review.
- Netlify must deploy the updated netlify/functions/merchant-help.js function and the new store-ai.js asset.
- After deployment, hard refresh the merchant dashboard and public shop.
- Test with a non-production/test merchant account first. Verify one read-only question, then create/update one disposable test product and approve one test status update.
- Do not paste API keys or session tokens into support chats.

VALIDATION SCOPE
Static JavaScript syntax checks and ZIP integrity checks are run before delivery. This package has not been tested against the live Supabase project or live Netlify deployment. No claim of live end-to-end verification is made.
