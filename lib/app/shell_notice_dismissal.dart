import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which shell-level storage notice ([StorageRetryBanner] /
/// [StoragePressureBanner]) the user has closed, if any.
///
/// Mirrors `offline_banner_dismissal.dart`'s `SyncBannerDismissalController`
/// architecture on purpose — same problem shape, same fix.
///
/// **Why a shared provider and not each banner's own `State`** (what both of
/// them used to keep this in). A per-`State` field is invisible to any OTHER
/// widget, which is exactly the bug this closes:
/// `topos_screen.dart`'s `_StorageDetailNotice` exists ONLY as the
/// Library-screen companion to [StorageRetryBanner]'s explanation (see that
/// widget's own doc) — it renders precisely when [ShellNotices] is already
/// showing that banner above it. With the dismissal living in
/// [StorageRetryBanner]'s own `State`, closing the shell's banner left
/// `_StorageDetailNotice` on screen with no context (the sentence it was
/// annotating was gone) and no way to close it either — an orphaned
/// diagnostic line. Reading the SAME provider both banners now write to lets
/// any third widget render exactly when the banner it companions would.
///
/// **Signature, not a bare bool.** [ShellNotices] can only ever show ONE of
/// [StorageRetryBanner]/[StoragePressureBanner] at a time (see its own
/// priority doc), so one shared slot is enough — but keying it on the KIND
/// plus the exact notice TEXT (see [signature]), same as
/// `SyncBannerDismissalController`, is what lets an escalating message
/// (`StorageRetryBanner`'s `idle -> failed`, which adds a second paragraph)
/// still re-arm within one mount, exactly as the old per-`State`
/// `_dismissedNotice` comparison did.
///
/// **Episode-scoped via [reportCurrent]** — the identical mechanism
/// `SyncBannerDismissalController` uses, generalized from the SAME insight:
/// an acknowledgement must not survive the condition it was acknowledging
/// actually clearing and then recurring, even with byte-identical wording
/// (in practice inevitable here: [StoragePressureBanner.message] never
/// varies at all, so without this a single dismissal would silence EVERY
/// future storage-pressure warning for the rest of the session). [ShellNotices]
/// computes, on every build, the signature of whichever storage notice it is
/// about to show (or `null`), and reports it here; a stale dismissal clears
/// the instant that reads `null`.
class ShellNoticeDismissalController extends Notifier<String?> {
  /// The identity of one shell storage notice: its kind plus the exact text
  /// it renders. See `SyncBannerDismissalController.signature` for why a
  /// signature, not a bare bool, is the whole story.
  static String signature(String kind, String text) => '$kind|$text';

  @override
  String? build() => null;

  /// The user closed the notice identified by [noticeSignature] (build it
  /// with [signature]). Takes effect everywhere that reads
  /// [shellNoticeDismissalProvider] until either the signature changes (a
  /// different/escalated message) or [reportCurrent] observes the condition
  /// has genuinely cleared.
  void dismiss(String noticeSignature) {
    state = noticeSignature;
  }

  /// Called by [ShellNotices] on every build with the signature of whichever
  /// shell storage notice it is CURRENTLY about to show, or `null` when
  /// neither applies. Clears a stale dismissal the instant that reads `null`
  /// — see the class doc's "episode scoped" paragraph.
  ///
  /// Only ever CLEARS [state]; a non-null [currentSignature] never sets it —
  /// setting the dismissal is [dismiss]'s job alone, driven by an explicit
  /// user tap. Safe to call unconditionally on every build (idempotent,
  /// cheap); [ShellNotices] defers the call by a microtask, matching
  /// `offline_banner_dismissal.dart`'s identical convention for mutating a
  /// provider from a value computed during a widget's `build`.
  void reportCurrent(String? currentSignature) {
    if (state != null && currentSignature == null) {
      state = null;
    }
  }
}

/// The signature of the shell storage notice the user has currently
/// dismissed, or `null` if none is. See [ShellNoticeDismissalController] for
/// the full contract.
final shellNoticeDismissalProvider =
    NotifierProvider<ShellNoticeDismissalController, String?>(
      ShellNoticeDismissalController.new,
    );
