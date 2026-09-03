import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../shared/presentation/masi_icon.dart';

/// Builds an explicit, [MasiIcon]-branded back control for use as an
/// `AppBar.leading` value on WEB, on a route reached by being pushed above
/// something else — restoring an in-app way back on the web, where there is
/// no reliable browser-chrome back control to fall back on:
///
///  * Safari (desktop + iOS) deliberately gets NO browser-history entries at
///    all — see `is_safari.dart`'s doc on `router.dart`'s
///    `routerNeglect: isSafariBrowser()` — trading that away for the #76
///    edge-swipe-flash fix (a WebKit compositor artifact on the native
///    interactive back gesture that could not otherwise be removed).
///  * Chromium/Gecko etc. are NOT covered by that trade — `routerNeglect` is
///    `false` there, so `go_router` pushes real history entries and the
///    actual browser Back button already works. But an INSTALLED standalone
///    PWA (any engine) has no browser chrome at all — no Back button, no
///    history UI, nothing — so relying on browser-level back is never a
///    complete answer on web regardless of engine.
///
/// Returns `null` (never a zero-size placeholder widget) whenever the
/// control should NOT show, so callers can pass the result straight into
/// `AppBar(leading: ...)`: a `null` leading falls through to
/// `AppBar.automaticallyImplyLeading`'s own default handling, i.e. NATIVE
/// keeps rendering Flutter's ordinary Material back arrow exactly as it
/// always has — this is a pure ADDITION for web, never a replacement of
/// native chrome. Returning an empty widget instead of `null` would be
/// wrong: `AppBar.leading` treats any non-null value (even a zero-size one)
/// as "leading handled" and suppresses the framework's own default back
/// arrow — that would silently regress native.
///
/// Two independent gates, both must pass:
///  1. Web only — the real compile-time [kIsWeb] by default. [isWeb] exists
///     purely so a widget test can force this branch: `flutter test` always
///     runs on the Dart VM (never web/wasm), so [kIsWeb] is permanently
///     `false` under test — this mirrors the identical `{bool? isWeb}` seam
///     already used by `photo_source_sheet.dart`'s `showCameraOption`,
///     `auth_repository.dart`, and `sync_service.dart`.
///  2. Something to actually go back to — [Navigator.canPop]. Never shown
///     on a top-level shell tab (Topos/Map/Feed — each is the root of its
///     own branch [Navigator], so `canPop` is always `false` there) or on a
///     route reached directly rather than pushed (e.g. the web auth wall
///     landing a signed-out visitor straight on `/account`).
Widget? webBackLeading(BuildContext context, {bool? isWeb}) {
  if (!(isWeb ?? kIsWeb)) return null;
  if (!Navigator.canPop(context)) return null;
  return IconButton(
    key: const Key('web-back-button'),
    icon: const MasiIcon('chevron_left'),
    tooltip: 'Back',
    onPressed: () => Navigator.of(context).maybePop(),
  );
}
