/// The browser's answer to "may I send this person notifications".
///
/// Mirrors the Notification API's three states rather than collapsing them to a
/// bool, because they need three different responses from the UI and the middle
/// one is the whole reason: [denied] is a dead end the app cannot reopen — only
/// the user can, in browser settings — so offering them a button that silently
/// does nothing is worse than saying so.
enum PushPermission {
  /// Never asked. The only state where prompting is allowed to work.
  prompt,

  granted,

  /// Refused. `requestPermission()` will resolve `denied` immediately without
  /// showing anything, forever, until the user changes it in site settings.
  denied,

  /// No Push API, no service worker, or not a secure context. Native builds,
  /// and any browser too old to matter.
  unsupported,
}

/// A push subscription as the server needs it.
///
/// The two keys are the client's half of the payload encryption — Web Push
/// messages are encrypted end-to-end to them, which is why holding this record
/// lets somebody send a push to the device but never read one.
typedef PushSubscriptionData = ({
  String endpoint,
  String p256dh,
  String auth,
  String? userAgent,
});
