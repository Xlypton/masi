import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'push_registration_types.dart';

export 'push_registration_types.dart';

/// What the browser currently says about notifications for this origin.
///
/// Reads `Notification.permission` rather than remembering an answer of our
/// own, because the user can revoke it in site settings at any moment and
/// nothing tells the page when they do. A cached "granted" would leave the UI
/// claiming push is on while every send silently goes nowhere.
PushPermission pushPermission() {
  if (!_supported()) return PushPermission.unsupported;
  return switch (web.Notification.permission) {
    'granted' => PushPermission.granted,
    'denied' => PushPermission.denied,
    _ => PushPermission.prompt,
  };
}

/// Asks for permission if needed, then subscribes this device.
///
/// Returns `null` for every "no push here" outcome — unsupported, refused, or
/// a push service that would not issue a subscription. None of those is an
/// error worth throwing over: the in-app inbox works regardless, and push is an
/// addition to it.
///
/// **Must be called from a user gesture.** Safari (and, increasingly, Chrome)
/// refuses `requestPermission()` outside one, and iOS refuses it entirely
/// unless the PWA has been installed to the home screen. That is why this is
/// wired to a switch the user taps and never to app start.
Future<PushSubscriptionData?> subscribeToPush(String vapidPublicKey) async {
  if (!_supported()) return null;

  if (web.Notification.permission != 'granted') {
    final result = await web.Notification.requestPermission().toDart;
    if (result.toDart != 'granted') return null;
  }

  // `ready`, not `getRegistration()`: the worker may still be installing on a
  // first visit, and subscribing against a registration that is not yet active
  // throws.
  final registration = await web.window.navigator.serviceWorker.ready.toDart;

  final existing = await registration.pushManager.getSubscription().toDart;
  if (existing != null) {
    final data = _read(existing);
    // A subscription issued under a DIFFERENT VAPID key cannot receive our
    // pushes — the push service checks the signature against the key the
    // subscription was created with. If our keys ever rotate, the old
    // subscription has to go rather than be reported as working.
    if (data != null) return data;
    await existing.unsubscribe().toDart;
  }

  final options = web.PushSubscriptionOptionsInit(
    // Required by every browser: a push that shows the user nothing is not
    // allowed, and asking for silent push gets the subscription refused.
    userVisibleOnly: true,
    applicationServerKey: _decodeVapid(vapidPublicKey).toJS,
  );

  final subscription = await registration.pushManager.subscribe(options).toDart;
  return _read(subscription);
}

/// This device's existing subscription, or `null`. Used to reconcile on sign-in
/// — the browser is authoritative here, never our own stored copy.
Future<PushSubscriptionData?> currentPushSubscription() async {
  if (!_supported()) return null;
  try {
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    final existing = await registration.pushManager.getSubscription().toDart;
    return existing == null ? null : _read(existing);
  } catch (_) {
    return null;
  }
}

/// Drops this device's subscription. Best-effort: a browser that will not give
/// it up is not a reason to leave the UI stuck.
Future<bool> unsubscribeFromPush() async {
  if (!_supported()) return false;
  try {
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    final existing = await registration.pushManager.getSubscription().toDart;
    if (existing == null) return true;
    return (await existing.unsubscribe().toDart).toDart;
  } catch (_) {
    return false;
  }
}

/// Push needs a service worker AND the Push API AND a secure context. Checked
/// together because a browser missing any one of them behaves identically from
/// here, and because `Notification` alone existing proves nothing — Safari had
/// it for years before it could receive a push.
bool _supported() {
  try {
    return web.window.has('Notification') &&
        web.window.has('PushManager') &&
        web.window.navigator.has('serviceWorker');
  } catch (_) {
    return false;
  }
}

PushSubscriptionData? _read(web.PushSubscription subscription) {
  final p256dh = _key(subscription, 'p256dh');
  final auth = _key(subscription, 'auth');
  if (p256dh == null || auth == null) return null;
  return (
    endpoint: subscription.endpoint,
    p256dh: p256dh,
    auth: auth,
    userAgent: web.window.navigator.userAgent,
  );
}

/// A subscription key as unpadded base64url, which is the shape `web-push`
/// expects on the server.
String? _key(web.PushSubscription subscription, String name) {
  final buffer = subscription.getKey(name);
  if (buffer == null) return null;
  final bytes = buffer.toDart.asUint8List();
  if (bytes.isEmpty) return null;
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Decodes the base64url VAPID public key into the raw bytes
/// `applicationServerKey` wants.
///
/// Hand-rolled padding because `base64Url.decode` requires the `=` that VAPID
/// keys are conventionally published without — feeding it the bare key throws,
/// which would surface as "push just does not work" with no clue why.
Uint8List _decodeVapid(String key) {
  final normalised = key.replaceAll('-', '+').replaceAll('_', '/');
  final padding = (4 - normalised.length % 4) % 4;
  return base64.decode(normalised + ('=' * padding));
}
