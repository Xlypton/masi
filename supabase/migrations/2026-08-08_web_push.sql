-- Web Push: getting a notification onto a phone with the app closed.
--
-- The notifications table and its triggers already record WHAT happened. This
-- is the delivery leg, and it needs three things the database cannot do on its
-- own: a place to keep each device's push endpoint, a way to call out to
-- something that can sign and encrypt a Web Push message, and the credentials
-- to make that call.
--
-- Signing is why an Edge Function is unavoidable. Web Push requires a VAPID JWT
-- and an ECDH+AES128GCM-encrypted payload; that is not something to hand-roll
-- in plpgsql, and the VAPID private key must never be readable by a client.
--
-- Idempotent throughout, like every migration here.

-- pg_net gives the trigger a way to make an HTTP call that does NOT block the
-- transaction. That property is the whole reason it is used rather than
-- anything synchronous: this fires from a trigger on `notifications`, which
-- fires from a trigger on `comments`, so a slow or dead push endpoint would
-- otherwise make POSTING A COMMENT hang.
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Where a device's push endpoint lives.
-- ---------------------------------------------------------------------------
--
-- A Push Subscription is issued by the BROWSER's push service (FCM for Chrome,
-- Mozilla autopush, Apple's for Safari/iOS). It is per-device and per-origin,
-- so one climber signed in on a phone and a laptop is two rows and the sender
-- has to fan out to both.
--
-- Deliberately NOT mirrored into Drift, unlike `notifications`. There is
-- nothing to render from it and nothing to read offline, and the device's own
-- `pushManager.getSubscription()` is always fresher than any cache — a local
-- copy could only ever disagree with the browser about the truth.
--
-- `p256dh` and `auth` are the client's encryption keys. Payloads are encrypted
-- end-to-end to them, which is why a leak of this table alone lets somebody
-- send a push but not read one.
create table if not exists public.push_subscriptions (
  id           text primary key,
  "ownerId"    text not null,
  endpoint     text not null,
  p256dh       text not null,
  auth         text not null,
  "userAgent"  text,
  "createdAt"  bigint not null,
  "updatedAt"  bigint not null,
  -- Stamped when the push service says the endpoint is gone (404/410). Kept
  -- rather than deleted so a device that unsubscribes and resubscribes does not
  -- silently accumulate rows, and so a spike in failures stays visible.
  "failedAt"   bigint
);

create unique index if not exists push_subscriptions_endpoint_key
  on public.push_subscriptions (endpoint);

create index if not exists push_subscriptions_owner_live
  on public.push_subscriptions ("ownerId")
  where "failedAt" is null;

alter table public.push_subscriptions enable row level security;

-- Owner-scoped, matching every other owned table here: `text` compared to a
-- CAST auth.uid(), never a bare uuid.
--
-- Note what is deliberately NOT granted: no policy lets a client read another
-- user's endpoint, because an endpoint plus its keys is capability enough to
-- push to that device. The Edge Function reads with the service role, which
-- bypasses RLS.
drop policy if exists push_subscriptions_owner_all on public.push_subscriptions;
create policy push_subscriptions_owner_all
  on public.push_subscriptions
  for all
  to authenticated
  using ("ownerId" = (auth.uid())::text)
  with check ("ownerId" = (auth.uid())::text);

-- ---------------------------------------------------------------------------
-- The credentials the trigger needs to call out.
-- ---------------------------------------------------------------------------
--
-- A private schema with NO grants to any client role. `anon` and
-- `authenticated` are real roles rather than members of PUBLIC, so revoking
-- from PUBLIC alone would leave them able to read this — the same trap that
-- produced SEC-1/SEC-2 in this project. They are named explicitly.
--
-- This holds a shared secret, not the service-role key. The Edge Function only
-- needs to know the call came from us; giving the database a copy of the
-- service key to make that point would put a far more powerful credential in a
-- table for no extra benefit.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.push_config (
  id         int primary key default 1 check (id = 1),
  hook_url   text not null,
  hook_token text not null,
  constraint push_config_singleton check (id = 1)
);
revoke all on private.push_config from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The trigger that asks for a send.
-- ---------------------------------------------------------------------------
--
-- Fires on a notification INSERT and posts its id to the Edge Function. Only
-- the id: the function reads the row itself with the service role, so a
-- payload that got mangled in transit cannot cause a push describing something
-- that did not happen.
--
-- EVERYTHING is swallowed. This sits at the end of a chain that starts with
-- somebody posting a comment, and no failure to deliver a push may ever roll
-- that back. An unconfigured `private.push_config` is the normal state before
-- the first deploy and is silently a no-op.
create or replace function public.send_push_for_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  cfg private.push_config%rowtype;
begin
  select * into cfg from private.push_config where id = 1;
  if not found or cfg.hook_url is null or cfg.hook_url = '' then
    return null;
  end if;

  -- `net.http_post`, NOT `extensions.net.http_post`. pg_net registers the
  -- EXTENSION in `extensions` but installs its FUNCTIONS into a schema of its
  -- own called `net`, so the three-part form is parsed as
  -- database.schema.function and dies with "cross-database references are not
  -- implemented" on every single call. Together with the blanket handler below
  -- that silently discarded every push for a day: notification rows were
  -- created normally, nothing was ever sent, and — because the call never got
  -- as far as pg_net — there was no queue entry, no response row and no
  -- function log to find it by.
  perform net.http_post(
    url := cfg.hook_url,
    body := jsonb_build_object('notificationId', NEW.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-masi-push-token', cfg.hook_token
    ),
    -- Bounded so a hung endpoint cannot pile requests up in pg_net's queue.
    timeout_milliseconds := 5000
  );
  return null;
exception when others then
  -- A push nobody receives is a worse outcome than no push, and both are far
  -- better than a comment that fails to post — so this still swallows.
  -- It no longer swallows SILENTLY, though: the warning is what turns the next
  -- occurrence into a one-line grep of the Postgres log instead of a day spent
  -- guessing which of four hops dropped the message.
  raise warning 'send_push_for_notification failed for %: % (%)',
    NEW.id, sqlerrm, sqlstate;
  return null;
end;
$$;

revoke all on function public.send_push_for_notification() from public, anon, authenticated;

drop trigger if exists send_push_on_notification on public.notifications;
create trigger send_push_on_notification
  after insert on public.notifications
  for each row execute function public.send_push_for_notification();
