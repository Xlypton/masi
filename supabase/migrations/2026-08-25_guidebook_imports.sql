-- guidebook_imports — pending guidebook-page imports written by the MCP server.
--
-- Phase 2 of the guidebook import (MCP_SERVER_PLAN.md). A chat app photographs
-- a guidebook page and calls `create_import`, which lands a row here. The app
-- picks it up, runs it through the SAME decoder and review sheet a pasted
-- import uses, and only then writes routes.
--
-- The MCP server deliberately does NOT write routes directly. A model that
-- misreads a page would otherwise silently mutate the user's topo with no undo,
-- and the review step already exists from Phase 1 — so both paths end the same
-- way, with a human looking at what is about to be added.
--
-- Idempotent: safe to re-apply.

create table if not exists public.guidebook_imports (
  id          text primary key,
  "ownerId"   text   not null,
  "wallId"    text   not null,
  "photoId"   text   not null,

  -- The model's payload, stored EXACTLY as it arrived.
  --
  -- Not validated here on purpose. The client already has the Phase 1 decoder
  -- (`guidebook_import_codec.dart`), and its verdict is the one the user
  -- actually sees. A second server-side validator would be two decoders that
  -- have to agree forever, and the day they disagree the server would reject
  -- something the app could have read, or accept something it cannot.
  payload     jsonb  not null,

  "createdAt" bigint not null,

  -- Set when the app has applied (or dismissed) this import. Kept rather than
  -- deleted so a second device does not re-offer an import the user already
  -- dealt with.
  "consumedAt" bigint
);

-- No foreign keys to walls/photos, matching the other sync tables. Rows here
-- arrive from a different client than the one that created the wall, and the
-- sync engine re-pushes full state in an order it does not promise — a server
-- FK would reject a legitimate import purely for arriving early.

alter table public.guidebook_imports enable row level security;

-- Same owner-policy shape as every other table on this project: text ownerId
-- compared against a cast auth.uid(). This is the whole authorization story for
-- the MCP server — it calls Supabase with the USER'S token, never a service
-- role key, so RLS is what stops one person's chat app reaching another
-- person's library.
drop policy if exists guidebook_imports_owner_all on public.guidebook_imports;
create policy guidebook_imports_owner_all
  on public.guidebook_imports
  for all
  using ("ownerId" = (auth.uid())::text)
  with check ("ownerId" = (auth.uid())::text);

-- The app's only query: "anything pending for me?"
create index if not exists guidebook_imports_owner_pending_idx
  on public.guidebook_imports ("ownerId", "consumedAt");
