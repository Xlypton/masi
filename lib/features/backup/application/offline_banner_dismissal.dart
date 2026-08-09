import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reachability_providers.dart';

/// Which `SyncBanner` the user has closed, if any — as an opaque SIGNATURE of
/// the thing that was acknowledged, not a bare `true`.
///
/// **Why a provider and not a `bool` in each screen's `State`.** The banner is
/// one condition rendered on two screens — the Library (`topos_screen.dart`)
/// and the Community Feed (`community_feed_screen.dart`). Acknowledging it is
/// therefore one act, not two: closing it on the Library must close it on the
/// Feed as well, or the user has to dismiss the same sentence again on the
/// next tab. That also rules out `install_banner.dart`'s local
/// `bool _dismissed` as a model here — besides being per-widget, it dies on
/// remount, and both of these screens are remounted by ordinary navigation.
///
/// **Why a signature and not a bool.** Every `SyncBannerKind` is dismissible
/// now, including `syncFailed` (the user's decision — see `SyncBanner.onDismiss`
/// for why the old "never dismissible" rule was wrong on the facts as well as
/// on the user's preference). A bare bool would mean "I have closed A sync
/// banner", which would let today's acknowledgement of a deferred-rows message
/// swallow tomorrow's genuine failure in silence. The signature makes the
/// acknowledgement specific to the message that was actually read: a different
/// [signature] is a different message, and an un-dismissed one.
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
/// **The two re-arming rules are the load-bearing part — see [build] and
/// [signature].**
class SyncBannerDismissalController extends Notifier<String?> {
  /// The identity of one banner message: its kind, plus the error text it is
  /// reporting (`null` for the kinds that carry a fixed sentence).
  ///
  /// This is what makes a dismissal cover THIS message and no other. The
  /// underlying error changing — different text, or absent -> present — yields
  /// a different signature, which no longer matches the stored one, so the
  /// banner comes back. That is the error-side equivalent of the offline
  /// episode reset in [build], and it exists for the same reason: an
  /// acknowledgement of one problem must not be able to hide the next one.
  ///
  /// Takes `kindName` as a plain [String] (callers pass `kind.name`) rather
  /// than the enum, so this application-layer provider does not have to import
  /// a presentation widget to describe its own state.
  static String signature(String kindName, String? detail) =>
      '$kindName|${detail ?? ''}';

  /// Whether the currently-stored dismissal expires when the signal comes
  /// back. True only for the offline banner — see [build].
  ///
  /// Deliberately a plain field rather than part of [state]: it is bookkeeping
  /// about the acknowledgement, not something any widget rebuilds on, and
  /// keeping it out of the state type is what lets `state` stay a simple
  /// nullable signature that a reader can compare with `==`.
  bool _endsWithOfflineEpisode = false;

  @override
  String? build() {
    // A dismissal of the OFFLINE banner covers THIS offline episode and no
    // other.
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
    //
    // Gated on [_endsWithOfflineEpisode] so it only ever clears the offline
    // acknowledgement. An ERROR dismissal is re-armed by its signature
    // changing instead, and clearing it here would resurrect a still-identical
    // error message every time a probe happened to flip — which on these
    // screens is every mount.
    ref.listen<Reachability>(reachabilityProvider, (previous, next) {
      if (state != null && _endsWithOfflineEpisode && !next.isKnownOffline) {
        _endsWithOfflineEpisode = false;
        state = null;
      }
    });
    return null;
  }

  /// The user closed the banner whose identity is [bannerSignature] (build it
  /// with [signature]). Takes effect on every screen that renders that same
  /// banner, until either the signature changes or — when
  /// [endsWithOfflineEpisode] — the signal comes back.
  void dismiss(
    String bannerSignature, {
    required bool endsWithOfflineEpisode,
  }) {
    _endsWithOfflineEpisode = endsWithOfflineEpisode;
    state = bannerSignature;
  }
}

/// The signature of the `SyncBanner` the user has currently dismissed, or
/// `null` if none is dismissed.
///
/// Read it as `ref.watch(syncBannerDismissalProvider) == thisBannersSignature`
/// to decide whether to render the banner, and call
/// `ref.read(syncBannerDismissalProvider.notifier).dismiss(...)` from its close
/// button.
///
/// EVERY `SyncBannerKind` consults this, including `syncFailed` and
/// `sharedPhotosWithheld`. That reverses this file's previous rule, which said
/// `syncFailed` "is deliberately NOT dismissible — it is the only signal that
/// the user's work may not have reached the cloud". Do not restore it: the
/// user decided otherwise, and the claim was wrong anyway — the text this
/// banner renders is `lastPullError`, which is PULL-only, so a failed PUSH
/// (the case where the user's work really might not have reached the cloud)
/// never sets it at all. See `SyncBanner.onDismiss` for the full argument, and
/// [SyncBannerDismissalController.signature] for what stops a dismissal from
/// hiding a LATER, different failure.
final syncBannerDismissalProvider =
    NotifierProvider<SyncBannerDismissalController, String?>(
      SyncBannerDismissalController.new,
    );
