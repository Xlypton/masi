-- Adds `profiles."avatarUrl"` — the user's profile picture.
--
-- Local Drift schema v10 -> v11 (`app_database.dart`'s `from < 11` branch)
-- adds the same column. This delta must be applied to the LIVE project
-- BEFORE a client build carrying v11 ships, or the first profile push sends
-- a column the server does not have: that is the schema-drift bug class this
-- project keeps hitting (#64/#65/#72).
--
-- The column holds either an `https://` avatar URL or an inline
-- `data:image/jpeg;base64,...` URL for a picture the user chose themselves
-- (see `tables.dart`'s `Profiles.avatarUrl` doc for why it is stored inline
-- rather than in Supabase Storage). Nullable, no default: an existing row
-- reads back NULL, meaning "no picture", and callers fall back to the
-- provider avatar and then to the initials chip.
--
-- Idempotent, per this repo's migration convention.

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS "avatarUrl" text;
