import 'push_registration_types.dart';

export 'push_registration_types.dart';

/// Native builds and plain-Dart tests. There is no Push API here, and every
/// caller already has to handle [PushPermission.unsupported] — a browser
/// without a service worker reports the same thing — so this needs no special
/// case anywhere upstream.
PushPermission pushPermission() => PushPermission.unsupported;

/// Never reached in practice: the UI only offers to subscribe when the
/// permission is [PushPermission.prompt] or [PushPermission.granted], which
/// this platform never reports.
Future<PushSubscriptionData?> subscribeToPush(String vapidPublicKey) async =>
    null;

Future<PushSubscriptionData?> currentPushSubscription() async => null;

Future<bool> unsubscribeFromPush() async => false;
