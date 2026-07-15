import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../application/auth_providers.dart';
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
  bool _sending = false;
  bool _linkSent = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
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
        _error = 'Enter a valid email address.';
      });
      return;
    }

    // Dismiss the keyboard as soon as a real send attempt is under way —
    // otherwise the still-focused email field leaves the keyboard up while
    // the "sending"/confirmation UI renders underneath it.
    FocusManager.instance.primaryFocus?.unfocus();

    // Reset both the confirmation and any prior error at the START of every
    // attempt (not just the error), so a later failed send can never render
    // the stale "link sent" confirmation and the new error message at the
    // same time.
    setState(() {
      _sending = true;
      _linkSent = false;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendMagicLink(email);
      if (!mounted) return;
      setState(() => _linkSent = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not send the link: $e');
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
                  sending: _sending,
                  linkSent: _linkSent,
                  error: _error,
                  onSend: _handleSendLink,
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Something went wrong: $error'),
                const SizedBox(height: 8),
                ElevatedButton(
                  key: const Key('account-error-retry'),
                  onPressed: () => ref.invalidate(authStateProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
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
    required this.sending,
    required this.linkSent,
    required this.error,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final bool linkSent;
  final String? error;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Container(
          padding: const EdgeInsets.all(MasiSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.large),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sign in', style: textTheme.titleLarge),
              const SizedBox(height: MasiSpacing.sm),
              Text(
                "Enter your email and we'll send you a link to sign in — "
                'no password needed.',
                style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.lg),
              TextField(
                key: const Key('account-email-field'),
                controller: controller,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
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
                child: const Text('Send magic link'),
              ),
              if (linkSent) ...[
                const SizedBox(height: MasiSpacing.md),
                Text(
                  'Check your email for a link to sign in.',
                  key: const Key('account-link-sent'),
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
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
/// card styling as [_SignedOutBody].
class _SignedInBody extends StatelessWidget {
  const _SignedInBody({required this.email, required this.onSignOut});

  final String email;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Container(
          padding: const EdgeInsets.all(MasiSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.large),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                onPressed: onSignOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
