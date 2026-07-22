import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../topo/presentation/canvas_chrome.dart';
import '../application/auth_providers.dart';
import '../application/email_initials.dart';
import '../application/profile_providers.dart';
import '../application/pwa_install.dart';
import '../application/pwa_install_providers.dart';
import '../application/pwa_install_types.dart';
import '../data/auth_repository.dart';

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
      setState(() => _error = 'Google sign-in failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _handleSignOut() async {
    try {
      await ref.read(authRepositoryProvider).signOut();
    } catch (e, st) {
      // Defensive, matching `topos_screen.dart`'s style for repo-call
      // failures: a network hiccup on sign-out must never crash the screen.
      debugPrint('Sign out failed: $e\n$st');
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
      body: SafeArea(
        child: asyncAuth.when(
          data: (session) => session.isSignedIn
              ? _SignedInBody(
                  email: session.email!,
                  onSignOut: _handleSignOut,
                )
              : _SignedOutBody(
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
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          // A permanent, value-less AsyncError here (e.g. main()'s
          // documented Supabase.initialize()-failed catch-and-continue
          // fallback — see `_webAuthGateRedirect`'s doc in
          // `lib/app/router.dart`) is treated as UNAUTHENTICATED, exactly
          // like the `data`-signed-out branch above, rather than a dead-end
          // "Something went wrong" screen with no way to even attempt
          // sign-in: this is the sign-in view the web auth wall's fail
          // -CLOSED redirect lands an errored visitor on, so it must
          // actually offer the sign-in form.
          error: (error, stackTrace) => _SignedOutBody(
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
  final VoidCallback onSend;

  /// Submits the emailed sign-in code (`account-otp-submit`) via
  /// [_AccountScreenState._handleVerifyOtp]. iOS-web only.
  final VoidCallback onVerifyOtp;

  /// Starts a Google OAuth sign-in (`account-google-signin`), an alternative
  /// to the magic-link flow. Disabled while [sending] is true so it can't
  /// race a magic-link send already in flight.
  final VoidCallback onGoogle;

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
                ElevatedButton(
                  key: const Key('account-send-link'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: colors.accent,
                    disabledForegroundColor: colors.onAccent.withValues(
                      alpha: 0.7,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: sending ? null : onSend,
                  child: Text(
                    iosWeb ? 'Email me a sign-in code' : 'Send magic link',
                  ),
                ),
              ],
              const SizedBox(height: MasiSpacing.md),
              ElevatedButton(
                key: const Key('account-google-signin'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.surface2,
                  foregroundColor: colors.ink,
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
                  ElevatedButton(
                    key: const Key('account-otp-submit'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      disabledBackgroundColor: colors.accent,
                      disabledForegroundColor: colors.onAccent.withValues(
                        alpha: 0.7,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
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
class _SignedInBody extends ConsumerStatefulWidget {
  const _SignedInBody({required this.email, required this.onSignOut});

  final String email;
  final VoidCallback onSignOut;

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
              Center(
                child: CircleAvatar(
                  key: const Key('account-avatar'),
                  radius: 24,
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  child: Text(
                    emailInitials(email),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
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
                  return Text(
                    _syncStatusLabel(syncState),
                    key: const Key('sync-status'),
                    style: textTheme.bodySmall?.copyWith(color: colors.ink2),
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
                  ElevatedButton(
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                    onPressed: _saving ? null : _handleSaveDisplayName,
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
              ElevatedButton(
                key: const Key('account-sign-out'),
                style: ElevatedButton.styleFrom(
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

  /// The iOS fallback: Safari has no programmatic install API, so the best
  /// this app can do is explain the manual Share-sheet steps.
  void _showAddToHomeScreenDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add to Home Screen'),
        content: const Text(
          'To install: tap the Share button in your browser, then choose '
          "'Add to Home Screen'.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
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
String _syncStatusLabel(SyncOrchestratorState state) {
  switch (state.status) {
    case SyncStatus.syncing:
      return 'Syncing…';
    case SyncStatus.error:
      return 'Sync error';
    case SyncStatus.offline:
      return 'Offline';
    case SyncStatus.idle:
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
