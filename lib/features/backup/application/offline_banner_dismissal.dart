import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// **The uniform re-arming rule — see [reportCurrent].** A dismissal covers
/// exactly the message that was acknowledged, and no other, for TWO
/// independent reasons that must both hold:
///
///  1. A DIFFERENT message (different kind, or the same kind with different
///     detail text) does not match the stored [signature] by simple string
///     comparison — see [signature] itself. This is what stops an
///     acknowledgement of a deferred-rows message from swallowing tomorrow's
///     genuine failure, and it needs no help from this controller: every
///     caller already renders `null` unless its freshly-computed signature
///     equals the dismissed one.
///  2. The SAME message recurring AFTER THE CONDITION CLEARED must also be
///     un-dismissed — otherwise a user who dismissed "you're offline" once
///     would never be told again for the rest of the session, no matter how
///     many times connectivity dropped and came back; the same was true, even
///     more sharply, for `sharedPhotosWithheld` (whose signature is a
///     CONSTANT, since it carries no varying detail — see [reportCurrent]'s
///     doc) and, less obviously, for `syncFailed` whenever two genuinely
///     separate failures happen to produce byte-identical wording (common:
///     network errors have stock messages). Rule 1 cannot catch this case
///     because the message truly is identical; only knowing that the
///     condition actually WENT AWAY in between can. That is what
///     [reportCurrent] is for.
class SyncBannerDismissalController extends Notifier<String?> {
  /// The identity of one banner message: its kind, plus the error text it is
  /// reporting (`null` for the kinds that carry a fixed sentence).
  ///
  /// This is what makes a dismissal cover THIS message and no other — rule 1
  /// of the class doc's re-arming pair. Takes `kindName` as a plain [String]
  /// (callers pass `kind.name`) rather than the enum, so this
  /// application-layer provider does not have to import a presentation
  /// widget to describe its own state.
  static String signature(String kindName, String? detail) =>
      '$kindName|${detail ?? ''}';

  @override
  String? build() => null;

  /// The user closed the banner whose identity is [bannerSignature] (build it
  /// with [signature]). Takes effect on every screen that renders that same
  /// banner, until either the signature changes (rule 1) or [reportCurrent]
  /// observes the condition has genuinely cleared (rule 2).
  void dismiss(String bannerSignature) {
    state = bannerSignature;
  }

  /// Called by every screen that renders this banner family, on EVERY build,
  /// with the signature of whichever `SyncBannerKind` condition is CURRENTLY
  /// true straight off the shared condition sources (reachability, the
  /// orchestrator's `lastPullError`, the shared-photo budget reason) — or
  /// `null` when none of them is.
  ///
  /// Clears a stale dismissal the instant [currentSignature] reads `null`:
  /// that is the uniform "an episode ends when the condition clears" rule,
  /// generalized from what used to be an offline-only special case (a
  /// `ref.listen<Reachability>` here that reset the acknowledgement only for
  /// [SyncBannerKind.offline], and left `syncFailed`/`sharedPhotosWithheld`
  /// dismissals permanent for the rest of the session once the message
  /// recurred byte-for-byte — the exact bug this method exists to close: a
  /// storage-pressure dismissal survived any number of clear-then-refill
  /// cycles because [sharedPhotosWithheld]'s signature never varies, and an
  /// identically-worded second network failure was suppressed by the first
  /// one's acknowledgement even though the two outages were unrelated).
  ///
  /// **Callers must pass the RAW condition, never their own displayed
  /// `bannerKind`.** Both screens also suppress the banner in favour of a
  /// sibling empty/error state that already reports the same fact more
  /// prominently (`topos_screen.dart`'s `emptyStateOwnsTheError`/
  /// `asyncToposHardError`, `community_feed_screen.dart`'s `showSyncError`) —
  /// that is a display decision, not proof the underlying condition resolved.
  /// Feeding THAT suppressed value in here would report `null` the moment a
  /// search query merely emptied a list, and silently forget a still-live
  /// failure's acknowledgement scope.
  ///
  /// Only ever CLEARS [state]; a non-null [currentSignature] never sets it —
  /// setting the dismissal is [dismiss]'s job alone, driven by an explicit
  /// user tap. Safe to call unconditionally on every build (idempotent,
  /// cheap): callers defer the call by a microtask, matching this file's
  /// established convention for mutating a provider from information computed
  /// during a widget's `build` (see `topos_screen.dart`'s `_pullModerationFor`
  /// for the same pattern) rather than doing so synchronously inside it.
  void reportCurrent(String? currentSignature) {
    if (state != null && currentSignature == null) {
      state = null;
    }
  }
}

/// The signature of the `SyncBanner` the user has currently dismissed, or
/// `null` if none is dismissed.
///
/// Read it as `ref.watch(syncBannerDismissalProvider) == thisBannersSignature`
/// to decide whether to render the banner, and call
/// `ref.read(syncBannerDismissalProvider.notifier).dismiss(...)` from its close
/// button. Every reader that renders a banner from this provider must ALSO
/// call `reportCurrent` with its raw (pre-suppression) condition on every
/// build — see that method's doc — or a cleared-then-recurred condition can
/// stay wrongly suppressed for the rest of the session.
///
/// EVERY `SyncBannerKind` consults this, including `syncFailed` and
/// `sharedPhotosWithheld`. That reverses this file's previous rule, which said
/// `syncFailed` "is deliberately NOT dismissible — it is the only signal that
/// the user's work may not have reached the cloud". Do not restore it: the
/// user decided otherwise, and the claim was wrong anyway — the text this
/// banner renders is `lastPullError`, which is PULL-only, so a failed PUSH
/// (the case where the user's work really might not have reached the cloud)
/// never sets it at all. See `SyncBanner.onDismiss` for the full argument, and
/// [SyncBannerDismissalController.signature]/[SyncBannerDismissalController
/// .reportCurrent] for what stops a dismissal from hiding a LATER occurrence,
/// whether different or byte-identical.
final syncBannerDismissalProvider =
    NotifierProvider<SyncBannerDismissalController, String?>(
      SyncBannerDismissalController.new,
    );
