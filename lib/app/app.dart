import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/application/auth_providers.dart';
import '../features/account/data/auth_repository.dart';
import '../features/backup/application/sync_orchestrator.dart';
import '../features/library/application/library_providers.dart';
import 'claim_ownership_bootstrap.dart';
import 'last_known_uid_bootstrap.dart';
import 'router.dart';
import 'theme.dart';
import 'web_lifecycle.dart';

class MasiApp extends ConsumerStatefulWidget {
  const MasiApp({super.key});

  @override
  ConsumerState<MasiApp> createState() => _MasiAppState();
}

class _MasiAppState extends ConsumerState<MasiApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Web-only, best-effort hardening (ADDITIVE — the `WidgetsBindingObserver`
    // above is unchanged and still runs on every platform including web):
    // browsers don't reliably deliver `AppLifecycleState.paused` on a plain
    // tab-hide/close the way iOS/Android deliver it on backgrounding, so
    // there's otherwise no trigger to flush a pending debounced sync push
    // before the tab disappears. `installWebLifecycleFlush` is a no-op on
    // native (see `web_lifecycle_native.dart`) — this call is inert there.
    // Same target as the native `AppLifecycleState.paused` branch below:
    // push immediately, skipping any pending debounce window. See
    // `web_lifecycle_web.dart` for exactly which browser events this hooks
    // and its honest limitation (can't guarantee completion on abrupt close,
    // only maximizes the chance the push starts in time).
    installWebLifecycleFlush(
      () => ref.read(syncOrchestratorProvider.notifier).onAppPaused(),
    );
    // Seed the last-known-uid bootstrap (§1c) with whatever the auth stream
    // ALREADY holds, once. `build()`'s `ref.listen` below only fires on
    // SUBSEQUENT emissions — `WidgetRef.listen` has no `fireImmediately` — and
    // `Supabase.initialize` has completed by the time MasiApp builds, so an
    // `initialSession` emission may already have been delivered and would
    // otherwise be missed entirely.
    //
    // The `Future<void>.microtask` wrapper is LOAD-BEARING, not cosmetic:
    // `remember`/`forget` write `lastKnownUidProvider`'s state synchronously,
    // and Riverpod forbids modifying a provider during a widget build. One
    // microtask puts the write safely after the first frame's build — the same
    // deferral `database_provider.dart` uses for its storage verdict.
    Future<void>.microtask(() {
      if (!mounted) return;
      _handleLastKnownUid(ref.read(authStateProvider));
    });
  }

  /// Wires `handleAuthStateForLastKnownUid` to the real providers. Shared by
  /// the one-shot seed in [initState] and the `ref.listen` in [build] so both
  /// paths apply identical semantics: keep the uid on an involuntary
  /// sign-out, clear it only on a user-initiated one.
  void _handleLastKnownUid(AsyncValue<AuthSessionState> next) {
    final lastKnown = ref.read(lastKnownUidProvider.notifier);
    handleAuthStateForLastKnownUid(
      next,
      remember: (uid) => unawaited(lastKnown.remember(uid)),
      forget: () => unawaited(lastKnown.forget()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Push immediately (skipping any pending debounce window) whenever the
    // app leaves the foreground — it may get killed before a debounced push
    // would otherwise have fired, silently losing whatever was written
    // since the last sync.
    if (state == AppLifecycleState.paused) {
      ref.read(syncOrchestratorProvider.notifier).onAppPaused();
    }
    // #57: re-pull own+shared data whenever the app returns to the
    // foreground. Without this, the ONLY pull trigger is the signed-out ->
    // signed-in edge (see `SyncOrchestrator.build`'s doc) — an
    // already-signed-in user who simply backgrounds and resumes the app
    // never re-syncs, so another user's newly-published topo (rendered from
    // the LOCAL `watchSharedTopos()` query, not fetched live) stays
    // invisible until a full sign-out/sign-in. `pullNow()` self-guards
    // against overlapping calls and is already a safe no-op when signed
    // out / Supabase is unavailable (see its doc) — no extra gating needed
    // here. `throttled: true` because on web `resumed` also fires on plain
    // browser tab-focus (not just a genuine relaunch) — see `pullNow`'s doc
    // for the throttle window; explicit user-initiated pulls elsewhere
    // (pull-to-refresh, map refresh, "Try again") stay unthrottled.
    // Fire-and-forget (`unawaited`): this lifecycle callback must return
    // immediately, never block on network I/O.
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(syncOrchestratorProvider.notifier).pullNow(throttled: true),
      );
      // §1e (S2): a resume is also the moment to FLUSH anything that never
      // made it up — an edit made offline, or a push that failed while the
      // app was backgrounded. Before this, resume only ever pulled, so a user
      // who edited offline and then merely backgrounded/foregrounded the app
      // stayed unsynced indefinitely (the only push triggers were a local
      // write's 2s debounce and `onAppPaused()`).
      //
      // Deliberately UNthrottled, unlike the pull above: `pushNow()` is
      // already self-limiting in three independent ways — it coalesces
      // against an in-flight push, it no-ops when nothing is locally `dirty`
      // (so web's resume-on-every-tab-focus costs one indexed LIMIT-1 query,
      // not a network round trip), and it is a safe no-op when signed out.
      // Fire-and-forget: this lifecycle callback must return immediately.
      unawaited(ref.read(syncOrchestratorProvider.notifier).pushNow());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the opportunistic-sync orchestrator ACTIVELY watched for the
    // entire app run (not just constructed once via `ref.read`). This
    // matters for a non-obvious Riverpod reason spelled out in
    // `sync_orchestrator.dart`'s doc comment: `SyncOrchestrator`'s own
    // `ref.listen(authStateProvider, ...)` (its pull-on-sign-in wiring) only
    // keeps firing while `syncOrchestratorProvider` itself has at least one
    // active watcher/listener — a one-off `ref.read` builds it once but its
    // internal auth listener silently goes dead the moment nothing is left
    // watching it. This widget lives for the whole app run, so watching it
    // here keeps that listener alive permanently. (Its debounced-push
    // subscription to `tableUpdates()` is a plain Stream subscription and
    // would keep working either way — this is specifically about the
    // Riverpod-internal auth listener.)
    ref.watch(syncOrchestratorProvider);

    // Claim-on-sign-in bootstrap (P2): on the signed-out -> signed-in edge
    // of the live auth stream, attribute any locally-created, still-unowned
    // rows to the newly-signed-in uid exactly once. Edge-detection and the
    // "never throw" guard live in `handleAuthStateForClaimOwnership` (unit
    // tested on its own); this listener just wires it to the real
    // providers. Installed at the app root (rather than e.g. only on the
    // Account screen) so it fires regardless of which screen is on-screen
    // when sign-in completes (deep-linked magic-link return can land
    // anywhere the router currently is).
    ref.listen<AsyncValue<AuthSessionState>>(authStateProvider, (
      previous,
      next,
    ) {
      handleAuthStateForClaimOwnership(
        previous,
        next,
        (uid) => ref.read(libraryCrudRepositoryProvider).claimOwnership(uid),
      );
    });

    // Last-known-uid bootstrap (§1c): keep `lastKnownUidProvider` in step with
    // the live auth stream so local data scoping survives an involuntary
    // sign-out. A SEPARATE listener from the claim-ownership one above,
    // deliberately: the claim handler is an edge-detector whose semantics
    // depend on `previous`, whereas this one is a pure function of the current
    // emission. The already-held value is covered by `initState`'s one-shot
    // seed, since `WidgetRef.listen` cannot fire immediately.
    ref.listen<AsyncValue<AuthSessionState>>(
      authStateProvider,
      (previous, next) => _handleLastKnownUid(next),
    );

    return MaterialApp.router(
      title: 'masi',
      debugShowCheckedModeBanner: false,
      theme: MasiTheme.light,
      darkTheme: MasiTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
      // Global tap-to-dismiss-keyboard: a translucent GestureDetector over
      // the whole routed app that unfocuses whatever text field currently
      // has focus whenever the user taps empty space. `translucent` (not
      // `opaque`) so the tap still reaches — and is still handled by — any
      // interactive widget underneath (buttons, text fields, etc.); Flutter's
      // gesture arena resolves the ambiguity in favor of the more specific
      // descendant recognizer when one is hit, so this only ever fires on
      // taps that land on non-interactive space.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
    );
  }
}
