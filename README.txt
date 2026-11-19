ORDERDESK NG — R5.3 COMMERCIAL UPGRADE REVIEW BUILD

Start here:
- R5_3_COMMERCIAL_UPGRADE_README.txt — features, migration prerequisites and
  Netlify environment variables.
- R5_3_RELEASE_TEST_CHECKLIST.txt — required test sequence.
- MASTER_IMPLEMENTATION_STATUS.txt — what is implemented and what remains.

New database migration:
- r5_3_commercial_upgrade.sql

Important:
This package has not been deployed and the new SQL has not been executed against
Supabase. Do not run it on production until you have a database backup and the
release checklist has passed in a test project. Do not rerun migrations that
have already been applied. Never put Supabase service-role, Groq or Cloudflare API tokens
in browser files.


R5.3 AI + IMAGE STORAGE SETUP
Read R5_3_CLOUDFLARE_CLOUDINARY_SETUP.txt for Cloudflare Workers AI and Cloudinary environment variables. Gemini image generation is not used.
