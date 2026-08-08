// Sends one notification to every device its recipient has registered.
//
// This exists as an Edge Function rather than in the database because Web Push
// needs a VAPID JWT and an ECDH+AES128GCM-encrypted payload. Neither is
// something to hand-roll in plpgsql, and the VAPID private key must live
// somewhere no client and no SQL role can read.
//
// Called by `public.send_push_for_notification()` on a notifications INSERT,
// carrying only the row id. Only the id on purpose: this reads the row itself
// with the service role, so nothing in the request body can make it describe an
// event that did not happen.
//
// Everything here is best-effort. A notification is already recorded and will
// show in the app's inbox on the next pull; failing to also buzz a phone is not
// worth a 500 that makes pg_net retry.

import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'jsr:@supabase/supabase-js@2';

const HOOK_SECRET = Deno.env.get('PUSH_HOOK_SECRET') ?? '';
const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY') ?? '';
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:noreply@climb-masi.pages.dev';

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
);

/// The sentence the phone shows.
///
/// Deliberately built here rather than read from a column: the wording has to
/// match what the in-app row says, and duplicating it in the trigger would mean
/// two places to change it. `preview` carries the comment excerpt; everything
/// else is derived from the kind.
function compose(kind: string, actor: string, preview: string | null) {
  switch (kind) {
    case 'comment':
      return { title: `${actor} commented on your topo`, body: preview ?? '' };
    case 'mention':
      return { title: `${actor} tagged you`, body: preview ?? '' };
    case 'like':
      return { title: `${actor} liked your topo`, body: '' };
    case 'suggestion':
      return { title: `${actor} suggested an edit`, body: preview ?? '' };
    default:
      // An unknown kind still notifies. A build of this function that predates
      // a new kind must degrade to something true and vague, not go silent —
      // silence is indistinguishable from "nothing happened".
      return { title: 'Something happened on your topo', body: preview ?? '' };
  }
}

Deno.serve(async (req) => {
  // A shared secret, not the service-role key. The function only needs to know
  // the call came from our database; handing the database a copy of the service
  // key to make that point would put a far more powerful credential in a table
  // for no extra benefit.
  if (!HOOK_SECRET || req.headers.get('x-masi-push-token') !== HOOK_SECRET) {
    return new Response('forbidden', { status: 403 });
  }

  let notificationId: string | null = null;
  try {
    const payload = await req.json();
    notificationId = typeof payload?.notificationId === 'string'
      ? payload.notificationId
      : null;
  } catch {
    notificationId = null;
  }
  if (!notificationId) return new Response('bad request', { status: 400 });

  const { data: note } = await admin
    .from('notifications')
    .select('id, recipientId, kind, actorId, wallId, ascentId, preview')
    .eq('id', notificationId)
    .maybeSingle();
  if (!note) return new Response('gone', { status: 200 });

  // The actor's name, or "Someone". Never the raw uid — the same rule the app's
  // own rows follow, and it matters more here because a push is read on a lock
  // screen with no context around it.
  let actorName = 'Someone';
  if (note.actorId) {
    const { data: profile } = await admin
      .from('profiles')
      .select('displayName')
      .eq('id', note.actorId)
      .maybeSingle();
    if (profile?.displayName?.trim()) actorName = profile.displayName.trim();
  }

  const { data: subs } = await admin
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth')
    .eq('ownerId', note.recipientId)
    .is('failedAt', null);
  if (!subs?.length) return new Response('no devices', { status: 200 });

  const { title, body } = compose(note.kind, actorName, note.preview);
  const url = note.ascentId
    ? `/community/ascent/${note.ascentId}`
    : note.wallId
    ? `/community/topo/${note.wallId}`
    : '/notifications';
  // One tag per subject, so ten comments on one topo replace each other on the
  // lock screen instead of burying everything else.
  const tag = note.ascentId ?? note.wallId ?? note.id;
  const payload = JSON.stringify({ title, body, url, tag });

  const dead: string[] = [];
  await Promise.all(subs.map(async (sub) => {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload,
      );
    } catch (error) {
      // 404/410 is the push service saying this endpoint is permanently gone —
      // the browser was uninstalled, or the subscription was revoked. Anything
      // else (a timeout, a 5xx) is transient and must NOT retire the device.
      const status = (error as { statusCode?: number })?.statusCode;
      if (status === 404 || status === 410) dead.push(sub.id);
    }
  }));

  if (dead.length) {
    await admin
      .from('push_subscriptions')
      .update({ failedAt: Date.now() })
      .in('id', dead);
  }

  return new Response(
    JSON.stringify({ sent: subs.length - dead.length, retired: dead.length }),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
