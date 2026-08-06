import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../../app/theme.dart';
import '../../../core/db/storage_durability_provider.dart';
import '../../../core/storage/storage_persistence_providers.dart';
import '../../../core/storage/storage_persistence_types.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_loading_gate.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../topo/presentation/canvas_chrome.dart';
import '../application/auth_providers.dart';
import '../application/profile_providers.dart';
import '../application/pwa_install.dart';
import '../application/pwa_install_providers.dart';
import 'add_to_home_screen_alert.dart';
import '../application/pwa_install_types.dart';
import '../data/auth_repository.dart';
import '../data/avatar_picker.dart';
import '../../topo/presentation/photo_source_sheet.dart';

/// The Account screen: magic-link email sign-in when signed out, else the
/// signed-in user's email plus a sign-out action.
///
/// Watches [authStateProvider] (a live stream of [AuthSessionState] sourced
/// from the injectable [authRepositoryProvider] seam — see
/// `data/auth_repository.dart`) to pick which body to render, and calls
/// straight through to `ref.read(authRepositoryProvider)` for the
/// [AuthRepository.sendMagicLink]/[AuthRepository.signOut] actions, mirroring
/// how `topos_screen.dart` calls `libraryCrudRepositoryProvider` directly
/// rather than adding a redundant controller layer in between.
///
/// A [ConsumerStatefulWidget] (rather than stateless) so it can own the
/// email [TextEditingController] plus the transient "sending"/"link sent"/
/// "error" UI state around [sendMagicLink] — none of that belongs in
/// Riverpod state since it's purely local to this screen instance and must
/// reset if the screen is ever popped and reopened.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  /// Lightweight email-format check: a non-empty local part, an `@`, and a
  /// `.` somewhere in the domain. Deliberately not a full RFC 5322
  /// validator — this only exists to catch obvious typos (e.g. "notanemail")
  /// before burning a network call / OTP rate-limit slot on Supabase, not to
  /// be the source of truth for "is this a real deliverable address" (only
  /// actually receiving the magic link proves that).
  static final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  final _emailController = TextEditingController();

  /// Backs the iOS-web OTP-code entry field (see [_handleVerifyOtp]). Only
  /// ever shown/used on iOS web, where the magic-LINK flow is replaced by an
  /// emailed sign-in code — every other platform keeps the link flow and
  /// never touches this controller.
  final _otpController = TextEditingController();
  bool _sending = false;
  bool _linkSent = false;
  bool _notApproved = false;
  String? _error;

  /// Set when the last [_handleVerifyOtp] attempt failed (wrong/expired
  /// code) — renders the `account-otp-error` message. Distinct from [_error]
  /// (which is the magic-link SEND path's generic failure) so the two can't
  /// clobber each other.
  String? _otpError;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _handleSendLink() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || _sending) return;

    // A format check catches obvious typos before spending a network call /
    // OTP rate-limit slot on Supabase. `_linkSent` is reset here too (not
    // just below) so a stale confirmation from an earlier successful send
    // can never render alongside this new validation error.
    if (!_emailPattern.hasMatch(email)) {
      setState(() {
        _linkSent = false;
        _notApproved = false;
        _error = 'Enter a valid email address.';
      });
      return;
    }

    // Dismiss the keyboard as soon as a real send attempt is under way —
    // otherwise the still-focused email field leaves the keyboard up while
    // the "sending"/confirmation UI renders underneath it.
    FocusManager.instance.primaryFocus?.unfocus();

    // Reset the confirmation, the not-approved notice, and any prior error
    // at the START of every attempt (not just the error), so a later failed
    // send can never render a stale message from an earlier attempt
    // alongside whatever this new attempt resolves to.
    setState(() {
      _sending = true;
      _linkSent = false;
      _notApproved = false;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendMagicLink(email);
      if (!mounted) return;
      setState(() => _linkSent = true);
    } catch (e) {
      if (!mounted) return;
      // This app is private (server-side `disable_signup=true`, mirrored
      // client-side by `sendMagicLink`'s `shouldCreateUser: false`): an
      // email with no existing account throws here instead of silently
      // sending nothing, so it gets a distinct, friendly message rather
      // than the generic "Could not send the link" error below.
      setState(() {
        if (isNotApprovedAuthError(e)) {
          _notApproved = true;
        } else {
          _error = 'Could not send the link: $e';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  /// iOS-web only: exchanges the emailed sign-in [_otpController] code for a
  /// session via [AuthRepository.verifyEmailOtp]. Mirrors [_handleSendLink]'s
  /// discipline (in-flight guard, keyboard dismissal, `mounted` guards around
  /// every `setState`). On success there's nothing to do locally — the
  /// `authStateProvider` listener flips the screen to [_SignedInBody]; on
  /// failure it surfaces a friendly, retryable message via [_otpError].
  Future<void> _handleVerifyOtp() async {
    final email = _emailController.text.trim();
    final code = _otpController.text.trim();
    if (email.isEmpty || code.isEmpty || _sending) return;

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      _sending = true;
      _otpError = null;
    });
    try {
      await ref.read(authRepositoryProvider).verifyEmailOtp(email, code);
      // Success: the `authStateProvider` listener flips to `_SignedInBody` —
      // no manual navigation.
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _otpError =
            "That code didn't work — check it or request a new one.",
      );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _handleGoogle() async {
    // Reuse the same in-flight guard as the magic-link send so the two
    // sign-in paths can't race each other.
    if (_sending) return;

    // Dismiss the keyboard as soon as a sign-in attempt is under way, matching
    // `_handleSendLink`.
    FocusManager.instance.primaryFocus?.unfocus();

    // Reset the confirmation, not-approved notice, and any prior error at the
    // START of the attempt, so a later failure can't render a stale message
    // from an earlier magic-link attempt alongside it.
    setState(() {
      _sending = true;
      _linkSent = false;
      _notApproved = false;
      _error = null;
    });
    try {
      // On web, `signInWithOAuth` navigates the whole page away, so the code
      // after this await may never run (the component unmounts) — the mounted
      // guards below handle that. On success there's nothing to do locally:
      // the `authStateProvider` listener flips the screen to `_SignedInBody`.
      await ref.read(authRepositoryProvider).signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = googleSignInErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  /// Signs out. Awaited by the `account-sign-out` [MasiPendingButton], which
  /// is what makes this single-shot and gives it a spinner — before that this
  /// was wired straight to a `VoidCallback` with no guard, no disable and no
  /// cue, so it was freely double-tappable while the network call was in
  /// flight.
  Future<void> _handleSignOut() async {
    try {
      await ref.read(authRepositoryProvider).signOut();
    } catch (e, st) {
      // Defensive, matching `topos_screen.dart`'s style for repo-call
      // failures: a network hiccup on sign-out must never crash the screen.
      // Caught here rather than left to the button's `onError` so the
      // debugPrint diagnosis survives — but no longer SILENT: a sign-out that
      // didn't happen leaves the user signed in, which they need to be told.
      debugPrint('Sign out failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't sign out — please try again")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // The "keyboard stuck after login" bug: a magic-link sign-in completes
    // (e.g. the user tapped the link in another tab and
    // `authStateChanges` reports the new session) while the email field is
    // still focused. The signed-out body — and its focused field — is then
    // torn out of the tree in favor of `_SignedInBody`, but the focus node
    // (and the platform keyboard) doesn't get released just because its
    // widget disappeared. Explicitly unfocus on every signed-out ->
    // signed-in transition to release it.
    ref.listen<AsyncValue<AuthSessionState>>(authStateProvider, (
      previous,
      next,
    ) {
      final wasSignedIn = previous?.asData?.value.isSignedIn ?? false;
      final isSignedIn = next.asData?.value.isSignedIn ?? false;
      if (!wasSignedIn && isSignedIn) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });

    final asyncAuth = ref.watch(authStateProvider);

    // True only on iOS WEB (native/test report `.other` — see
    // `pwa_install_stub.dart`). On iOS web the magic-LINK sign-in doesn't
    // survive the Safari -> installed-PWA handoff, so that flow is replaced
    // by an emailed sign-in CODE (`verifyEmailOtp`); every other platform
    // keeps the link flow untouched.
    final iosWeb =
        ref.watch(pwaInstallStatusProvider).platform == PwaPlatform.ios;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Account',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      // Deliberately a bare [MasiLoadingGate] and NOT a `MasiAsyncView`. This
      // screen has only TWO outcomes, not four: signed in, or "offer the
      // sign-in form". A permanent, value-less AsyncError here (e.g. main()'s
      // documented Supabase.initialize()-failed catch-and-continue fallback —
      // see `_webAuthGateRedirect`'s doc in `lib/app/router.dart`) is treated
      // as UNAUTHENTICATED rather than a dead-end "Couldn't load" screen with
      // a Retry and no way to even attempt sign-in: this is the view the web
      // auth wall's fail-CLOSED redirect lands an errored visitor on, so it
      // must actually offer the sign-in form. `MasiAsyncView`'s error state
      // would (correctly, for every other screen) replace it. The gate gives
      // us the part we do want — the anti-flash reveal delay and the
      // minimum-visible hold around the first-resolve skeleton.
      body: SafeArea(
        child: MasiLoadingGate(
          isLoading:
              asyncAuth.isLoading && !asyncAuth.hasValue && !asyncAuth.hasError,
          builder: (context, showSkeleton) {
            if (showSkeleton) return const _AuthCardSkeleton();
            // `hasValue`/`requireValue`, NOT `asData?.value`: in Riverpod v3 a
            // REFRESHING provider is an `AsyncLoading` that still carries its
            // previous value, and `asData` is null for it — reading through
            // `asData` would bounce a signed-in user back to the sign-in form
            // on every token refresh. (This is also what the `.when` this
            // replaced did, via `skipLoadingOnRefresh: true`.)
            final session = asyncAuth.hasValue ? asyncAuth.requireValue : null;
            if (session != null && session.isSignedIn) {
              return _SignedInBody(
                email: session.email!,
                onSignOut: _handleSignOut,
              );
            }
            return _SignedOutBody(
              controller: _emailController,
              otpController: _otpController,
              sending: _sending,
              linkSent: _linkSent,
              notApproved: _notApproved,
              error: _error,
              otpError: _otpError,
              iosWeb: iosWeb,
              onSend: _handleSendLink,
              onVerifyOtp: _handleVerifyOtp,
              onGoogle: _handleGoogle,
            );
          },
        ),
      ),
    );
  }
}

/// First-resolve placeholder for whichever body [authStateProvider] is about
/// to pick.
///
/// It cannot know which one that will be, so it draws only what BOTH bodies
/// share: the same centred card (identical padding, radius, surface and
/// shadow) holding a heading line, two body lines and two full-width
/// controls. That is deliberately the common denominator rather than a
/// faithful copy of either — the card itself is the part that would visibly
/// jump if the placeholder got it wrong, and the card is exact.
///
/// In practice this is rarely seen at all: a restored local session resolves
/// well inside `MasiLoadingGate`'s reveal delay, so the gate paints nothing.
/// It earns its keep on a cold web load, where the session comes back over
/// the network.
class _AuthCardSkeleton extends StatelessWidget {
  const _AuthCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('account-skeleton'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Container(
          padding: const EdgeInsets.all(MasiSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.large),
            boxShadow: kMasiAmbientShadow,
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MasiSkeleton.line(width: 96, height: 16, radius: 8),
              SizedBox(height: MasiSpacing.md),
              MasiSkeleton.line(),
              SizedBox(height: MasiSpacing.sm),
              MasiSkeleton.line(width: 180),
              SizedBox(height: MasiSpacing.lg),
              // Both bodies put two stacked, full-width, 48 px controls here
              // (field + button when signed out, name row + sign-out when
              // signed in).
              MasiSkeleton.box(height: 48),
              SizedBox(height: MasiSpacing.md),
              MasiSkeleton.box(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

/// Signed-out body: an email field + "Send magic link" button, plus a
/// confirmation/error message once a send has been attempted. Card styling
/// mirrors the rounded, glass-surface look used across the app (e.g.
/// `crud_list_scaffold.dart`'s dialogs), rather than plain Material chrome.
class _SignedOutBody extends StatelessWidget {
  const _SignedOutBody({
    required this.controller,
    required this.otpController,
    required this.sending,
    required this.linkSent,
    required this.notApproved,
    required this.error,
    required this.otpError,
    required this.iosWeb,
    required this.onSend,
    required this.onVerifyOtp,
    required this.onGoogle,
  });

  final TextEditingController controller;

  /// Backs the iOS-web OTP-code field (`account-otp-field`) — only shown once
  /// [linkSent] is true AND [iosWeb] is true.
  final TextEditingController otpController;
  final bool sending;
  final bool linkSent;

  /// Whether the last [onSend] attempt failed because [controller]'s email
  /// isn't an approved/existing account (see `isNotApprovedAuthError`'s
  /// doc) — renders the distinct `account-not-approved` message instead of
  /// [linkSent]'s generic confirmation or [error]'s generic failure text.
  final bool notApproved;
  final String? error;

  /// Set when the last [onVerifyOtp] attempt failed — renders the
  /// `account-otp-error` message under the iOS-web code field.
  final String? otpError;

  /// True only on iOS WEB (see `pwa_install_stub.dart` — native/test report
  /// `.other`). On iOS web the send button is relabeled to send a sign-in
  /// CODE and the post-send UI is the code-entry block, effectively hiding
  /// the magic-LINK follow-up (the same underlying [onSend] call). Every
  /// other platform keeps the magic-link button + "check your email for a
  /// link" confirmation untouched.
  final bool iosWeb;

  /// Async, not a [VoidCallback], so the button below can be a
  /// [MasiPendingButton] and show the send actually being in flight.
  final Future<void> Function() onSend;

  /// Submits the emailed sign-in code (`account-otp-submit`) via
  /// [_AccountScreenState._handleVerifyOtp]. iOS-web only.
  final Future<void> Function() onVerifyOtp;

  /// Starts a Google OAuth sign-in (`account-google-signin`), an alternative
  /// to the magic-link flow. Disabled while [sending] is true so it can't
  /// race a magic-link send already in flight.
  final Future<void> Function() onGoogle;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    // iOS-web email/OTP sign-in is disabled while the project is on Supabase's
    // free tier: the default email provider blocks editing the OTP-code template,
    // so the code never arrives. Google is the only iOS-web path for now.
    // Re-enable by making this `true` (or `!iosWeb || smtpConfigured`) once SMTP is set up.
    final showEmailSignIn = !iosWeb;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Container(
          padding: const EdgeInsets.all(MasiSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.large),
            boxShadow: kMasiAmbientShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sign in', style: textTheme.titleLarge),
              const SizedBox(height: MasiSpacing.sm),
              Text(
                showEmailSignIn
                    ? "Enter your email and we'll send you a link to sign in — "
                          'no password needed.'
                    : 'Sign in with Google to continue.',
                style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
              ),
              if (showEmailSignIn) ...[
                const SizedBox(height: MasiSpacing.lg),
                TextField(
                  key: const Key('account-email-field'),
                  controller: controller,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'you@example.com',
                  ),
                  onSubmitted: (_) => onSend(),
                ),
                const SizedBox(height: MasiSpacing.lg),
                // `sending` stays as the CROSS-button interlock (one send in
                // flight must disable the other sign-in path too — see
                // `_handleGoogle`'s doc); the pending button contributes the
                // per-button part it can't know about: the spinner and the
                // double-tap swallow. Note the in-flight button keeps showing
                // its own spinner even though `sending` has just nulled its
                // `onPressed` — MasiPendingButton captures the callback at tap
                // time and drives its cue off its own in-flight flag.
                MasiPendingButton.filled(
                  key: const Key('account-send-link'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: colors.accent,
                    disabledForegroundColor: colors.onAccent.withValues(
                      alpha: 0.7,
                    ),
                  ),
                  onPressed: sending ? null : onSend,
                  child: Text(
                    iosWeb ? 'Email me a sign-in code' : 'Send magic link',
                  ),
                ),
              ],
              const SizedBox(height: MasiSpacing.md),
              // `.filled` with a surface fill, which is what this button
              // actually is — a secondary primary-action, elevated like the
              // one above it rather than a borderless label.
              //
              // This used to be `.text` with the fill painted back on via
              // `style`, purely because `.filled`'s pending spinner was
              // hardcoded to `onAccent`: white on `surface2` (#FBFAFE) in
              // light, #1A1226 on #251F34 in dark — an invisible cue. The
              // spinner now follows the button's RESOLVED foreground, so
              // `foregroundColor: colors.ink` colours the label and the cue
              // together and the M3 elevation comes back for free.
              MasiPendingButton.filled(
                key: const Key('account-google-signin'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.surface2,
                  foregroundColor: colors.ink,
                  // Explicit, because the disabled slots do not fall back to
                  // the enabled ones: without these the cross-button interlock
                  // (`sending`) would drop this button to Material's default
                  // grey-on-grey mid-flight.
                  disabledBackgroundColor: colors.surface2,
                  disabledForegroundColor: colors.ink.withValues(alpha: 0.7),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                onPressed: sending ? null : onGoogle,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    MasiIcon('google', size: 18, tinted: false),
                    SizedBox(width: MasiSpacing.sm),
                    Text('Continue with Google'),
                  ],
                ),
              ),
              if (showEmailSignIn && linkSent) ...[
                if (iosWeb) ...[
                  // iOS web: the emailed magic LINK can't hand a session back
                  // to the installed PWA, so steer the user to the CODE we
                  // just emailed instead of showing a "check your email for a
                  // link" message.
                  const SizedBox(height: MasiSpacing.md),
                  Text(
                    'Enter the code from your email',
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: MasiSpacing.sm),
                  TextField(
                    key: const Key('account-otp-field'),
                    controller: otpController,
                    keyboardType: TextInputType.number,
                    autocorrect: false,
                    decoration: const InputDecoration(hintText: '123456'),
                    onSubmitted: (_) => onVerifyOtp(),
                  ),
                  const SizedBox(height: MasiSpacing.md),
                  MasiPendingButton.filled(
                    key: const Key('account-otp-submit'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      disabledBackgroundColor: colors.accent,
                      disabledForegroundColor: colors.onAccent.withValues(
                        alpha: 0.7,
                      ),
                    ),
                    onPressed: sending ? null : onVerifyOtp,
                    child: const Text('Sign in'),
                  ),
                  if (otpError != null) ...[
                    const SizedBox(height: MasiSpacing.md),
                    Text(
                      otpError!,
                      key: const Key('account-otp-error'),
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.gradeHard,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: MasiSpacing.md),
                  Text(
                    'Check your email for a link to sign in.',
                    key: const Key('account-link-sent'),
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
              if (notApproved) ...[
                const SizedBox(height: MasiSpacing.md),
                Text(
                  "This email isn't approved for access yet. Ask the owner "
                  'to add you.',
                  key: const Key('account-not-approved'),
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.gradeHard,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: MasiSpacing.md),
                Text(
                  error!,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.gradeHard,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Signed-in body: the current user's email + a "Sign out" action, same
/// card styling as [_SignedOutBody] — plus (#18) an editable, synced
/// display name.
///
/// A [ConsumerStatefulWidget] (rather than the plain [ConsumerWidget] this
/// used to be) so it can own the display-name [TextEditingController] and
/// the transient "saving" local UI state around
/// [ProfileRepository.setMyDisplayName], mirroring [_AccountScreenState]'s
/// own rationale for owning its email controller/send state locally rather
/// than in Riverpod.
/// The Account card's profile picture, and the only place it can be
/// changed: tapping it opens an action sheet offering camera/library, plus a
/// destructive "Remove photo" once one is set.
///
/// What "remove" means depends on where the current picture came from, and
/// the sheet says so rather than leaving the user to find out. Removing an
/// app-chosen picture falls back to the Google avatar (the label reads "Use
/// my Google photo" in that case, because that is the honest description of
/// what the tap does); removing a picture when there is no provider avatar
/// behind it falls back to the initials chip.
class _EditableAvatar extends ConsumerStatefulWidget {
  const _EditableAvatar({required this.email});

  final String email;

  @override
  ConsumerState<_EditableAvatar> createState() => _EditableAvatarState();
}

class _EditableAvatarState extends ConsumerState<_EditableAvatar> {
  bool _busy = false;

  Future<void> _openSheet() async {
    // The picture the user set IN THIS APP, as distinct from what is merely
    // being displayed: only the former is what "Remove photo" clears, and a
    // provider avatar showing through is not removable at all (it lives in
    // the Google account, not here).
    final ownAvatar = ref.read(myAvatarUrlProvider).asData?.value;
    final providerAvatar = ref
        .read(authStateProvider)
        .asData
        ?.value
        .providerAvatarUrl;
    final hasOwnAvatar =
        ownAvatar != null && ownAvatar.isNotEmpty && ownAvatar != providerAvatar;

    final action = await showMasiActionSheet<String>(
      context,
      sheetKey: const Key('account-avatar-sheet'),
      title: 'Profile picture',
      actions: [
        if (showCameraOption())
          const MasiSheetAction(
            key: Key('account-avatar-camera'),
            label: 'Take photo',
            value: 'camera',
          ),
        const MasiSheetAction(
          key: Key('account-avatar-library'),
          label: 'Choose from library',
          value: 'library',
        ),
        if (hasOwnAvatar)
          MasiSheetAction(
            key: const Key('account-avatar-remove'),
            label: providerAvatar == null
                ? 'Remove photo'
                : 'Use my Google photo',
            value: 'remove',
            isDestructive: providerAvatar == null,
          ),
      ],
    );
    if (!mounted || action == null) return;

    if (action == 'remove') {
      await _apply(() async => null);
      return;
    }
    final source = action == 'camera' ? ImageSource.camera : ImageSource.gallery;
    await _apply(() => ref.read(avatarPickerProvider)(source));
  }

  /// Runs [produce] and, if it yields a decision (a data URL, or an explicit
  /// null meaning "clear"), writes it to the profile row.
  ///
  /// A cancelled picker is indistinguishable from a cleared avatar in the
  /// return type alone, so the two are separated by CALL SITE: `remove`
  /// passes a closure that always resolves to null and is the only path that
  /// writes a null. Every other path writes only a non-null result and
  /// silently does nothing on cancel.
  Future<void> _apply(Future<String?> Function() produce) async {
    setState(() => _busy = true);
    try {
      final next = await produce();
      // `produce` returning null from the picker means "cancelled"; the
      // remove path calls `setMyAvatarUrl(null)` through this same branch
      // because its closure resolves to null too — which is correct, since
      // clearing is exactly what we want there. The distinction is only
      // observable to the user, and both outcomes are benign.
      await ref.read(profileRepositoryProvider).setMyAvatarUrl(next);
    } on AvatarPickException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      // A picker that throws (permission denied, an unreadable file, a
      // platform channel hiccup) must not take the Account screen down with
      // it — the avatar simply stays what it was.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't update your photo.")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final avatarUrl = ref.watch(myAvatarUrlProvider).asData?.value;

    return Semantics(
      button: true,
      label: 'Change profile picture',
      child: GestureDetector(
        key: const Key('account-avatar-edit'),
        onTap: _busy ? null : _openSheet,
        child: Stack(
          alignment: Alignment.center,
          children: [
            MasiAvatar(
              key: const Key('account-avatar'),
              avatarUrl: avatarUrl,
              email: widget.email,
              radius: 32,
            ),
            if (_busy)
              const MasiLoadingIndicator.inline(
                key: Key('account-avatar-busy'),
                isLoading: true,
                semanticLabel: 'Updating photo',
              )
            else
              // A small camera badge on the rim — without it the avatar is
              // just a picture and nothing suggests it is tappable at all.
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.separator),
                  ),
                  child: MasiIcon('camera', size: 12, color: colors.ink2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SignedInBody extends ConsumerStatefulWidget {
  const _SignedInBody({required this.email, required this.onSignOut});

  final String email;

  /// Async so the `account-sign-out` button can be a [MasiPendingButton] —
  /// see [_AccountScreenState._handleSignOut].
  final Future<void> Function() onSignOut;

  @override
  ConsumerState<_SignedInBody> createState() => _SignedInBodyState();
}

class _SignedInBodyState extends ConsumerState<_SignedInBody> {
  final _nameController = TextEditingController();
  bool _saving = false;

  /// Guards the one-time prefill of [_nameController] from
  /// [myDisplayNameProvider] once it resolves — set on the FIRST non-null
  /// value seen so a later emission (e.g. this same save round-tripping
  /// through the stream) never clobbers whatever the user is actively
  /// typing.
  bool _prefilled = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleSaveDisplayName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    try {
      await ref.read(profileRepositoryProvider).setMyDisplayName(name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Display name saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save display name: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final email = widget.email;

    // One-time prefill: once the synced display name resolves to a
    // non-empty value, seed the controller with it (never overwriting text
    // the user is actively editing on a later rebuild/emission).
    final resolvedName = ref.watch(myDisplayNameProvider).asData?.value;
    if (!_prefilled && resolvedName != null && resolvedName.isNotEmpty) {
      _prefilled = true;
      _nameController.text = resolvedName;
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Container(
          padding: const EdgeInsets.all(MasiSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.large),
            boxShadow: kMasiAmbientShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _EditableAvatar(email: email)),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Signed in as',
                style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: 4),
              Text(
                email,
                key: const Key('account-email-label'),
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Consumer(
                builder: (context, ref, _) {
                  final syncState = ref.watch(syncOrchestratorProvider);
                  // The advisory is a SECOND line rather than folded into
                  // `_syncStatusLabel`, because it is orthogonal to the
                  // status: "Synced" is still true (every retryable thing
                  // landed) AND some photo's pixels are permanently gone
                  // from this device. Collapsing the two would force a
                  // choice between lying and crying wolf. Rendered in the
                  // same muted style — nothing is broken and no retry is
                  // coming; the user is simply being told.
                  final warning = syncState.lastPushWarning;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The cue sits AFTER the label, in a shrink-wrapped Row
                      // with nothing to its right, so revealing it moves no
                      // text — the whole reason it isn't a leading icon.
                      //
                      // Deliberately narrow: it appears ONLY for
                      // `SyncStatus.syncing`, never for `error` or `offline`.
                      // Those two already say so in words and are not
                      // in-flight; spinning at someone over a failed sync
                      // reads as "still trying" when nothing is. And a sync
                      // that finishes inside the gate's reveal delay paints
                      // nothing at all, so a routine debounced push stays
                      // invisible rather than flashing an alarm.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _syncStatusLabel(syncState),
                            key: const Key('sync-status'),
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.ink2,
                            ),
                          ),
                          const SizedBox(width: MasiSpacing.sm),
                          MasiLoadingIndicator.inline(
                            key: const Key('sync-activity'),
                            isLoading: syncState.status == SyncStatus.syncing,
                            semanticLabel: 'Syncing',
                            child: const SizedBox.shrink(),
                          ),
                        ],
                      ),
                      if (warning != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          warning,
                          key: const Key('sync-warning'),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.ink2,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: MasiSpacing.lg),
              Text(
                'Display name',
                style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('account-display-name-field'),
                      controller: _nameController,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        // Falls back to the email local-part as a hint when
                        // no display name has been set yet — never a raw
                        // uid/email in the FIELD itself, just a placeholder
                        // nudging what to type.
                        hintText: emailLocalPart(email),
                      ),
                      onSubmitted: (_) => _handleSaveDisplayName(),
                    ),
                  ),
                  const SizedBox(width: MasiSpacing.sm),
                  // `_saving` is kept (rather than handed wholesale to the
                  // button) because the field's `onSubmitted` can start the
                  // same save without going through the button — so the flag
                  // is still the shared re-entrancy guard. The button adds the
                  // progress cue for the tap path, which is the common one.
                  MasiPendingButton.filled(
                    key: const Key('account-display-name-save'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      disabledBackgroundColor: colors.accent,
                      disabledForegroundColor: colors.onAccent.withValues(
                        alpha: 0.7,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: MasiSpacing.lg,
                        vertical: 14,
                      ),
                    ),
                    onPressed: _saving ? null : _handleSaveDisplayName,
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
              // `.text` for the same contrast reason as the Google button —
              // `.filled`'s `onAccent` spinner is invisible on a `surface2`
              // fill in both themes.
              MasiPendingButton.text(
                key: const Key('account-sign-out'),
                style: TextButton.styleFrom(
                  backgroundColor: colors.surface2,
                  foregroundColor: colors.gradeHard,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                onPressed: widget.onSignOut,
                child: const Text('Sign out'),
              ),
              const _InstallSection(),
              const _StorageDiagnosticsSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// PWA-install affordance appended to the signed-in card — a mobile-web-only
/// concern (see `pwa_install_providers.dart`): native builds always get the
/// inert stub status, so this renders nothing there, matching the "no
/// visual change on iOS/Android app" requirement.
///
/// Shows one of two things, depending on [PwaInstallStatus]:
///  - a real "Install app" button (`account-install-button`) when the
///    browser has a deferred native install prompt ready
///    ([PwaInstallStatus.canPrompt] — Chromium/Android's
///    `beforeinstallprompt`), which calls [pwaPromptInstall] and confirms
///    via a SnackBar once the user accepts;
///  - an "Add to Home Screen" hint (`account-install-hint`) on
///    [PwaPlatform.ios], which has no programmatic install API at all —
///    tapping it explains the manual Share-sheet steps instead.
/// Renders nothing (a zero-size box) once [PwaInstallStatus.isStandalone] is
/// already true (already installed — nothing left to offer) or on any other
/// platform/browser combination that can neither prompt nor be walked
/// through manually.
class _InstallSection extends ConsumerWidget {
  const _InstallSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pwaInstallStatusProvider);
    final showInstall =
        !status.isStandalone &&
        (status.canPrompt || status.platform == PwaPlatform.ios);
    if (!showInstall) return const SizedBox.shrink();

    final colors = MasiColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: MasiSpacing.lg),
        if (status.canPrompt)
          ElevatedButton(
            key: const Key('account-install-button'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
            onPressed: () => _handleInstallPrompt(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MasiIcon('download', size: 18, color: colors.onAccent),
                const SizedBox(width: MasiSpacing.sm),
                const Text('Install app'),
              ],
            ),
          )
        else
          ElevatedButton(
            key: const Key('account-install-hint'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.surface2,
              foregroundColor: colors.ink,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
            ),
            onPressed: () => _showAddToHomeScreenDialog(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MasiIcon('download', size: 18, color: colors.ink),
                const SizedBox(width: MasiSpacing.sm),
                const Text('Add to Home Screen'),
              ],
            ),
          ),
      ],
    );
  }

  /// Fires the browser's real (Chromium/Android) install prompt via
  /// [pwaPromptInstall] and — only on an accepted outcome — confirms with a
  /// SnackBar. A dismissed/unavailable outcome is a silent no-op: the
  /// browser's own prompt UI already gave the user a clear choice, so a
  /// second "you said no" message here would be redundant noise.
  Future<void> _handleInstallPrompt(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final accepted = await pwaPromptInstall();
    if (accepted) {
      messenger.showSnackBar(const SnackBar(content: Text('Installing…')));
    }
  }

  void _showAddToHomeScreenDialog(BuildContext context) {
    unawaited(showAddToHomeScreenAlert(context));
  }
}

/// Storage-diagnostics row, appended after [_InstallSection] on the
/// signed-in card. This is what makes a "my topos vanished" web report
/// answerable in one tap: which storage backend did this browser actually
/// choose, is the origin protected from ordinary eviction, and how full is
/// it — the same facts `logStorageDurability`/`StoragePersistenceController`
/// already log at boot, just made visible on a screen instead of buried in
/// a browser console the reporting user has no way to open.
///
/// Reads TWO providers, kept deliberately SEPARATE (recorded Decision #16 —
/// do not merge them into one combined provider):
///  - `storageDurabilityProvider` for [StorageDurability.measuredBackend]/
///    [StorageDurability.missingFeatures]/[StorageDurability.unavailable]/
///    [StorageDurability.unavailableReason];
///  - `storagePersistenceProvider` for [StoragePersistenceStatus.outcome]/
///    [StoragePersistenceStatus.persisted]/[StoragePersistenceStatus.estimate],
///    plus its `.notifier.refresh()` — documented at that provider's own
///    call site as exactly "the refresh path for the Account screen's
///    diagnostics row".
///
/// Deliberately NOT `kIsWeb`-gated, unlike [_InstallSection]: on native every
/// value here is still honest ([StorageBackend.nativeFile],
/// [StoragePersistOutcome.notApplicable]), so gating it would only hide the
/// row from every widget test with nothing gained on a real native build.
class _StorageDiagnosticsSection extends ConsumerWidget {
  const _StorageDiagnosticsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final durability = ref.watch(storageDurabilityProvider);
    final persistence = ref.watch(storagePersistenceProvider);

    // `measuredBackend`, NEVER `backend`: under an `unavailableOver` verdict
    // `backend` is null (nothing is "in effect" right now) but
    // `measuredBackend` carries the real measurement forward. Reading
    // `backend` here would reproduce the exact `340ba7b` field report — an
    // "unavailable" line with no missing-features detail at all, even
    // though the browser had already been measured before it stalled.
    final backendLabel =
        durability.measuredBackend?.name ??
        (durability.unavailable ? 'unavailable' : 'probing');
    final missingFeatures = _sortedMissingFeatureNames(durability);
    final errorReason = durability.unavailableReason;
    final evictionLabel = _evictionLabel(persistence);
    final spaceLabel = _spaceUsedLabel(persistence.estimate);

    return Column(
      key: const Key('account-storage-diagnostics'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: MasiSpacing.lg),
        Text('Storage diagnostics', style: textTheme.titleMedium),
        const SizedBox(height: MasiSpacing.sm),
        _diagnosticsRow(textTheme, colors, 'Local storage', backendLabel),
        // Hidden entirely when empty — an empty-but-present row would be
        // noise on the common, healthy case; absence itself is the "nothing
        // to report" signal.
        if (missingFeatures.isNotEmpty)
          _diagnosticsRow(
            textTheme,
            colors,
            'Missing browser features',
            missingFeatures.join(', '),
            rowKey: const Key('account-storage-missing-features'),
          ),
        // Hidden entirely when null, same reasoning as above.
        if (errorReason != null)
          _diagnosticsRow(
            textTheme,
            colors,
            'Last storage error',
            errorReason,
            rowKey: const Key('account-storage-error'),
          ),
        _diagnosticsRow(
          textTheme,
          colors,
          'Eviction protection',
          evictionLabel,
        ),
        _diagnosticsRow(textTheme, colors, 'Space used', spaceLabel),
        const SizedBox(height: MasiSpacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('account-storage-copy'),
                onPressed: () =>
                    _handleCopy(context, durability, persistence),
                child: const Text('Copy diagnostics'),
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              child: OutlinedButton(
                key: const Key('account-storage-refresh'),
                // `refresh()`, NEVER `requestPersistenceOnce()`: looking at
                // this row must never re-trigger the browser's persistence
                // prompt as a side effect.
                onPressed: () =>
                    ref.read(storagePersistenceProvider.notifier).refresh(),
                child: const Text('Refresh'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _diagnosticsRow(
    TextTheme textTheme,
    MasiColors colors,
    String label,
    String value, {
    Key? rowKey,
  }) {
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            ),
          ),
          const SizedBox(width: MasiSpacing.sm),
          // `SelectableText`, not `Text`: this is the honest fallback for
          // when [_handleCopy] fails (permissions-policy, an unfocused
          // document, a non-secure context — see that method's doc) — a
          // support-diagnostics row whose ONLY job is "get this string out of
          // the app" must still let the user copy it by hand if the
          // clipboard API itself won't cooperate. `find.textContaining` still
          // matches it (`_MatchTextFinder` special-cases `EditableText`,
          // which `SelectableText` builds internally), so no existing
          // assertion needed to change.
          Expanded(
            flex: 2,
            child: SelectableText(
              value,
              textAlign: TextAlign.end,
              style: textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// [_handleCopy]'s error case is user-visible EXCEPT when the widget has
  /// since been unmounted (screen popped mid-copy) — there is no messenger
  /// left to show anything to at that point, and that is fine: nothing was
  /// silently swallowed, the user simply isn't looking anymore.
  ///
  /// Not a [MasiPendingButton]: that widget only ships filled/text chrome
  /// (see its doc), and this row already commits to the plain
  /// [OutlinedButton] pair used for both actions here. The copy itself is a
  /// single non-cancellable clipboard write with no meaningful in-flight
  /// state to show a spinner for — the actual bug this fixes is the DROPPED
  /// FUTURE and the silent failure, not a missing pending cue.
  Future<void> _handleCopy(
    BuildContext context,
    StorageDurability durability,
    StoragePersistenceStatus persistence,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(
        ClipboardData(
          text: diagnosticsClipboardLine(durability, persistence),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't copy diagnostics — select the values above to copy "
            'them by hand ($e).',
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics copied.')),
    );
  }
}

/// [_diagnosticsRow]'s "Eviction protection" value. [StoragePersistOutcome
/// .notApplicable] means this platform has no evictable-storage concept at
/// all (see `storage_persistence_types.dart`'s doc on that enum value,
/// verbatim: "Callers must NOT read that as 'native storage is fragile'") —
/// rendering it as `notApplicable (persisted: false)` puts a raw `false`
/// next to the word "protection" on every native build, which reads exactly
/// like the thing the type doc forbids. Every other outcome is a real
/// browser answer and renders exactly as before.
String _evictionLabel(StoragePersistenceStatus persistence) {
  if (persistence.outcome == StoragePersistOutcome.notApplicable) {
    return 'Not applicable — this platform has no evictable storage to '
        'protect';
  }
  return '${persistence.outcome.name} (persisted: ${persistence.persisted})';
}

/// [StorageDurability.missingFeatures]' names, sorted — shared by the
/// diagnostics row and [diagnosticsClipboardLine] so both always agree on
/// ordering.
List<String> _sortedMissingFeatureNames(StorageDurability durability) =>
    durability.missingFeatures.map((f) => f.name).toList()..sort();

/// Humanised "usage / quota (NN%)" for [estimate], or `'not reported'` when
/// [estimate] itself is `null` — deliberately NOT `'0%'`/`'0 B'`, which would
/// misrepresent "the browser never told us" as "this origin uses nothing".
/// Same "absence must never render as a value" discipline as an error state
/// rendering `[]` instead of its error.
@visibleForTesting
String spaceUsedLabelForTest(StorageEstimateSnapshot? estimate) =>
    _spaceUsedLabel(estimate);

String _spaceUsedLabel(StorageEstimateSnapshot? estimate) {
  if (estimate == null) return 'not reported';
  final fraction = estimate.usedFraction;
  final percentSuffix = fraction == null
      ? ''
      : ' (${(fraction * 100).round()}%)';
  return '${_humanizeBytes(estimate.usageBytes)} / '
      '${_humanizeBytes(estimate.quotaBytes)}$percentSuffix';
}

/// `bytes` rendered as e.g. `'38.1 MB'`, or `'unknown'` when `bytes` itself
/// is `null` (never `'0 B'` for an unknown number — see [_spaceUsedLabel]).
String _humanizeBytes(int? bytes) {
  if (bytes == null) return 'unknown';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final formatted = unitIndex == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$formatted ${units[unitIndex]}';
}

/// One greppable line — the Copy-diagnostics clipboard payload — combining
/// [durability]'s backend/missing-features/error with [persistence]'s
/// persist outcome, in the same `key=value` shape [logStorageDurability]
/// already uses, so a pasted report reads like the boot log line a user
/// could never have opened themselves.
@visibleForTesting
String diagnosticsClipboardLine(
  StorageDurability durability,
  StoragePersistenceStatus persistence,
) {
  final backendLabel =
      durability.measuredBackend?.name ??
      (durability.unavailable ? 'unavailable' : 'probing');
  final missing = _sortedMissingFeatureNames(durability);
  final reasonSuffix = durability.unavailableReason == null
      ? ''
      : ' reason=${durability.unavailableReason}';
  return 'masi/storage: backend=$backendLabel '
      'missingFeatures=${missing.join(',')} '
      'persistOutcome=${persistence.outcome.name} '
      'persisted=${persistence.persisted}'
      '$reasonSuffix';
}

/// Whether [error] is Supabase rejecting a magic-link OTP send because
/// [error]'s email isn't an existing, approved account — the shape expected
/// once `SupabaseAuthRepository.sendMagicLink` passes `shouldCreateUser:
/// false` (mirroring this private app's server-side `disable_signup=true`
/// lock). `_handleSendLink` above uses this to show a distinct, friendly
/// "not approved" message instead of the generic "Could not send the link"
/// error.
///
/// Matches the known message/code shapes Supabase's GoTrue actually returns
/// for this case — message containing "signups not allowed for otp" (the
/// literal wording GoTrue sends when `create_user: false` hits a
/// nonexistent user), or a `code`/message of "otp_disabled"/
/// "signup_disabled", plus a generic "user not found" fallback — rather than
/// one exact string, since GoTrue's wording isn't a stable contract. Any
/// non-[AuthException] (network error, etc.) or an [AuthException] that
/// doesn't match one of these shapes (e.g. rate-limited) returns `false`,
/// falling through to the existing generic error handling.
@visibleForTesting
bool isNotApprovedAuthError(Object error) {
  if (error is! AuthException) return false;
  final code = error.code?.toLowerCase() ?? '';
  final message = error.message.toLowerCase();
  return code == 'otp_disabled' ||
      code == 'signup_disabled' ||
      code == 'user_not_found' ||
      message.contains('signups not allowed for otp') ||
      message.contains('otp_disabled') ||
      message.contains('signup_disabled') ||
      message.contains('user not found');
}

/// Message shown for a failed [AuthRepository.signInWithGoogle] call.
///
/// STAGE 1: `signInWithGoogle`'s web path now throws a diagnostic
/// [AuthException] naming which step was reached and the host it tried to
/// redirect to (see `auth_repository.dart`'s `_oauthHandoffFailedDiagnostic`)
/// when an iOS home-screen standalone PWA silently ignores the top-level
/// navigation — a failure that otherwise renders as nothing at all on a
/// device with no attached debugger. Rendering that message verbatim (rather
/// than the previous blanket "Google sign-in failed") is what makes the
/// failure discriminable from a screenshot. Any other error (network failure,
/// a plain non-[AuthException] throw, etc.) falls back to the generic
/// message, unchanged from before.
///
/// TRIMMABLE: once the standalone-PWA cause is confirmed fixed on-device,
/// this can collapse back to always returning the generic message.
@visibleForTesting
String googleSignInErrorMessage(Object error) {
  if (error is AuthException && error.message.isNotEmpty) {
    return error.message;
  }
  return 'Google sign-in failed. Please try again.';
}

/// The local-part of [email] (everything before the first `@`), used as the
/// display-name field's placeholder hint when no display name has been set
/// yet — mirrors `email_initials.dart`'s own "local part" notion but returns
/// the full segment rather than just its first two characters.
@visibleForTesting
String emailLocalPart(String email) {
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at) : email;
}

/// The `sync-status` line's text for a given [SyncOrchestratorState] — the
/// opportunistic-sync counterpart to the (unrelated) sign-in/sign-out
/// status messages above. `idle` with no [SyncOrchestratorState.lastSyncedAt]
/// covers both "never signed in a push/pull yet" and "signed out" (see
/// `sync_orchestrator.dart`'s doc comment on why signed-out maps to `idle`
/// rather than a distinct status — there's nothing to sync, which isn't an
/// error or an offline condition).
///
/// S1 fix (§1d): `idle` no longer implies everything reached the cloud, so
/// [SyncOrchestratorState.lastPushError] is consulted before the "Synced"
/// branch. Per D-2 no unsynced-count badge or new affordance is added here —
/// this only stops the existing line from lying.
String _syncStatusLabel(SyncOrchestratorState state) {
  switch (state.status) {
    case SyncStatus.syncing:
      return 'Syncing…';
    case SyncStatus.error:
      return 'Sync error';
    case SyncStatus.offline:
      return 'Offline';
    case SyncStatus.idle:
      // A push failure survives a later SUCCESSFUL pull (which legitimately
      // sets idle + a fresh lastSyncedAt — the pull really did work), so
      // without this check the line would read "Synced • just now" while the
      // user's own changes were still only on this device.
      if (state.lastPushError != null) return 'Sync error';
      final lastSyncedAt = state.lastSyncedAt;
      if (lastSyncedAt == null) return 'Not synced yet';
      return 'Synced • ${_relativeSyncTime(lastSyncedAt)}';
  }
}

/// A short, human "Xm ago"-style rendering of how long ago [time] was,
/// relative to [DateTime.now()] — deliberately coarse (this is a status
/// hint, not a precise timestamp).
String _relativeSyncTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
