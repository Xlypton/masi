-- Web Push: where a device's push endpoint lives.
--
-- A Push Subscription is issued by the BROWSER's push service (FCM for Chrome,
-- Mozilla autopush, Apple's for Safari/iOS). It is per-device and per-origin,
-- so one climber signed in on a phone and a laptop has two rows, and the
-- sender has to fan out to all of them.
--
-- WHY THIS IS NOT A DRIFT MIRROR, unlike `notifications`. There is nothing to
-- render from it and nothing to read offline — the only consumer is the Edge
-- Function that sends. The device's own current subscription is authoritative
-- in `navigator.serviceWorker.ready.pushManager.getSubscription()`, which is
-- always fresher than anything we could cache, so a local copy could only ever
-- disagree with the browser about the truth.
--
-- WHAT THE COLUMNS ARE. `endpoint` is the URL the push service gave us and is
-- the natural key: the browser can rotate it at any time, which issues a new
-- subscription rather than editing the old one. `p256dh` and `auth` are the
-- client's encryption keys — Web Push payloads are end-to-end encrypted to
-- them, which is why a leak of this table alone does not let anyone read the
-- content of a push, only send one.
create table if not exists public.push_subscriptions (
  id           text primary key,
  "ownerId"    text not null,
  endpoint     text not null,
  p256dh       text not null,
  auth         text not null,
  -- Diagnostics only: which browser/platform this row came from, so a
  -- systematically failing client is identifiable without guessing.
  "userAgent"  text,
  "createdAt"  bigint not null,
  "updatedAt"  bigint not null,
  -- Stamped when the push service tells us this endpoint is dead (a 404/410
  -- from the send). Kept rather than deleted so a device that unsubscribes and
  -- resubscribes does not silently accumulate rows, and so a spike in
  -- failures is visible.
  "failedAt"   bigint
);

-- One row per endpoint. `on conflict (endpoint)` is how the client upserts,
-- and it is what stops every app launch inserting a duplicate.
create unique index if not exists push_subscriptions_endpoint_key
  on public.push_subscriptions (endpoint);

-- The lookup the sender does, once per notification.
create index if not exists push_subscriptions_owner_live
  on public.push_subscriptions ("ownerId")
  where "failedAt" is null;

alter table public.push_subscriptions enable row level security;

-- Owner-scoped, matching every other owned table here: `text` compared to a
-- CAST auth.uid(), never a bare uuid.
--
-- A client may register and revoke ITS OWN subscriptions and nothing else.
-- Note what this deliberately does NOT grant: no policy lets a client read
-- another user's endpoint, which matters because an endpoint plus its keys is
-- capability enough to push to that device. The Edge Function reads with the
-- service role and bypasses RLS.
drop policy if exists push_subscriptions_owner_all on public.push_subscriptions;
create policy push_subscriptions_owner_all
  on public.push_subscriptions
  for all
  to authenticated
  using ("ownerId" = (auth.uid())::text)
  with check ("ownerId" = (auth.uid())::text);
