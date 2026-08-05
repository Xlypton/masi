import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reachability_providers.dart';

/// Whether the user has closed the OFFLINE `SyncBanner` for the offline
/// episode they are currently in.
///
/// **Why a provider and not a `bool` in each screen's `State`.** The banner is
/// one condition (`Reachability.offline`) rendered on two screens — the
/// Library (`topos_screen.dart`) and the Community Feed
/// (`community_feed_screen.dart`). Acknowledging it is therefore one act, not
/// two: closing it on the Library must close it on the Feed as well, or the
/// user has to dismiss the same sentence again on the next tab. That also
/// rules out `install_banner.dart`'s local `bool _dismissed` as a model here —
/// besides being per-widget, it dies on remount, and both of these screens are
/// remounted by ordinary navigation.
///
/// Riverpod v3 [Notifier] (never `StateProvider` — see CLAUDE.md), NOT
/// `autoDispose`, so the acknowledgement outlives a tab switch that unmounts
/// both readers.
///
/// **Session-scoped and in-memory on purpose.** Nothing here is persisted (no
/// `SharedPreferences` exists anywhere in `lib/`, and this is not the feature
/// to introduce one for): a dismissal that survived a relaunch would be a
/// setting, and "don't tell me I'm offline" is not a setting anyone means to
/// make permanently.
///
/// **The reset is the load-bearing part — see [build].**
class OfflineBannerDismissalController extends Notifier<bool> {
  @override
  bool build() {
    // A dismissal covers THIS offline episode and no other.
    //
    // Why that matters: this banner exists because of a specific reported bug
    // — a user WITH topos, offline at a crag, watched the list quietly fail to
    // refresh with no signal at all and no way to tell "stale cache" from "my
    // work is gone" (see `SyncBanner`'s own doc). A dismissal that survived an
    // offline -> online -> offline transition would recreate exactly that: the
    // next time the signal dropped, the user would again be shown a list that
    // silently stopped refreshing and told nothing. So the acknowledgement is
    // scoped to the episode that was acknowledged.
    //
    // `reachabilityProvider` carries no episode counter, timestamp or stream —
    // only the three-state enum (`reachability_providers.dart`) — so "a new
    // episode" is detected the only way that surface allows: by observing any
    // value that is NOT `offline`. Whatever comes after that (including
    // `offline` again) is a new episode, and un-dismissed.
    //
    // `isKnownOffline`, never `!= Reachability.online`: `unknown` is the
    // pre-probe state and must not be read as a verdict in either direction.
    ref.listen<Reachability>(reachabilityProvider, (previous, next) {
      if (!next.isKnownOffline && state) state = false;
    });
    return false;
  }

  /// The user closed the offline banner. Takes effect on every screen that
  /// renders it, until the reset in [build] fires.
  void dismiss() => state = true;
}

/// Whether the offline `SyncBanner` is currently dismissed. Read it to decide
/// whether to render the banner; call
/// `ref.read(offlineBannerDismissedProvider.notifier).dismiss()` from its close
/// button.
///
/// Only `SyncBannerKind.offline` consults this. `syncFailed` is deliberately
/// NOT dismissible — it is the only signal that the user's work may not have
/// reached the cloud, and letting it be hidden is how silent data loss becomes
/// invisible — and `sharedPhotosWithheld` is not dismissible either.
final offlineBannerDismissedProvider =
    NotifierProvider<OfflineBannerDismissalController, bool>(
      OfflineBannerDismissalController.new,
    );
