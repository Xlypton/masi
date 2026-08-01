import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'is_safari.dart';
import 'nav_shell.dart';
import '../features/account/application/auth_providers.dart';
import '../features/account/presentation/account_screen.dart';
import '../features/ar/presentation/ar_screen.dart';
import '../features/community/presentation/ascent_detail_screen.dart';
import '../features/community/presentation/community_screen.dart';
import '../features/community/presentation/community_topo_detail_screen.dart';
import '../features/library/presentation/areas_screen.dart';
import '../features/library/presentation/sectors_screen.dart';
import '../features/library/presentation/topos_screen.dart';
import '../features/library/presentation/walls_screen.dart';
import '../features/logbook/presentation/logbook_screen.dart';
import '../features/topo/presentation/topo_canvas_screen.dart';

/// Where the legacy `/community` deep link (`?tab=`/`?focus=` query params —
/// see `CommunityScreen`'s old `initialTab`/`focusWallId`, since replaced by
/// the persistent bottom-nav's separate Map (`/map`) and Feed (`/feed`)
/// branches — this app's real `home-community-button`/"Show on map" actions
/// still build this exact path) should redirect to.
///
/// Factored out as a pure function (rather than inlined in the `GoRoute`'s
/// `redirect` below) so the target-path logic is unit-testable directly
/// against a plain query-parameter map, without a real [GoRouterState].
///
/// `tab=feed` sends the legacy link to the Feed branch (`/feed`); anything
/// else (including no `tab` at all — `CommunityScreen` used to default to
/// Map) sends it to the Map branch (`/map`), carrying an optional
/// `focus=<wallId>` along as `/map`'s own `focus` query param, exactly as
/// `CommunityScreen.focusWallId` used to.
String communityRedirectTarget(Map<String, String> queryParameters) {
  if (queryParameters['tab'] == 'feed') return '/feed';
  final focus = queryParameters['focus'];
  return focus != null ? '/map?focus=$focus' : '/map';
}

/// The full-screen sign-in destination the web auth wall (see
/// [_webAuthGateRedirect]) sends a signed-out web visitor to: the existing
/// `/account` route below, which is declared as a top-level SIBLING of the
/// bottom-nav shell rather than one of its branches — it already builds on
/// the root navigator, full-screen, with no tabs exposed (see `NavShell`'s
/// class doc), and `AccountScreen` itself already renders the actual sign-in
/// UI (`_SignedOutBody`) purely from live [authStateProvider] state. No new
/// screen needed — just this route is reused as the wall's landing spot.
const String webAuthGateSignInPath = '/account';

/// Containers [_webAuthGateRedirect] has already wired an [authStateProvider]
/// refresh listener onto (see [_ensureAuthRefreshWired]) — keyed by object
/// identity via [Expando] rather than a [Set] so a disposed
/// [ProviderContainer] (e.g. a fresh one per widget test) is never kept
/// alive just to remember it was wired.
final Expando<Object> _authRefreshWired = Expando<Object>(
  'webAuthGateRefreshWired',
);

/// Web auth wall (private-app requirement, see `MASI.md`): on WEB,
/// while [webAuthGateEnabledProvider] is on, an unauthenticated visitor must
/// not reach ANY route except [webAuthGateSignInPath] itself. On NATIVE
/// (`webAuthGateEnabledProvider` false, its `kIsWeb`-derived default) this
/// function is a total no-op on the very first line — the local-first app
/// stays exactly as usable signed out as it was before this wall existed.
///
/// Reads live Riverpod state via [ProviderScope.containerOf] rather than
/// `ref.watch` because `appRouter` below is a plain module-level [GoRouter]
/// (like this file's pre-existing `communityRedirectTarget`-driven legacy
/// redirect), constructed once at import time, long before any
/// [ProviderContainer] exists — there's no provider to `watch` from here.
/// `context` is always a live descendant of whatever
/// [ProviderScope]/`UncontrolledProviderScope` wraps
/// `MaterialApp.router(routerConfig: appRouter, ...)`: go_router's own
/// `Router` widget passes ITS OWN mounted `BuildContext` into every
/// top-level `redirect` call (see go_router's `parser.dart`/`_navigate`), so
/// this lookup is safe everywhere this router is actually mounted —
/// `main.dart`'s real app and every existing router test's
/// `UncontrolledProviderScope`-wrapped harness alike.
///
/// Order of checks — fail closed ONLY when there is genuinely no session to
/// speak of. The ways past this function while the gate is on and you're not
/// already on the sign-in route are (a) genuine first-load loading (case 3),
/// (b) an errored auth stream while a KNOWN LOCAL SESSION exists — i.e.
/// signed-in-offline (case 4), and (c) a confirmed signed-in session
/// (case 5).
///  1. Gate disabled -> `null` (no redirect, ever) — the native no-op.
///  2. [webAuthGateSignInPath] itself is ALWAYS exempt, gate or no gate — a
///     signed-out visitor already on the sign-in view must stay there (no
///     redirect loop).
///  3. Genuinely still loading with NO value yet
///     (`AsyncValue.isLoading && !AsyncValue.hasValue` — the brief window
///     before the first `onAuthStateChange`/fake-stream emission, which on
///     web also spans Supabase's `detectSessionInUri` parsing a magic-link
///     `code` out of `Uri.base` at boot): don't bounce a would-be
///     -authenticated user off the page they actually asked for. Once the
///     stream resolves, [_ensureAuthRefreshWired]'s listener calls
///     [GoRouter.refresh] to re-run this redirect against the CURRENT
///     location with the now-known state.
///
///     NOTE this is intentionally NOT the same test as the old (buggy)
///     `!authAsync.hasValue`: [AsyncValue.hasValue] is ALSO false for a
///     value-less [AsyncError], and `main()` deliberately catches-and
///     -continues when `Supabase.initialize()` fails, which leaves
///     [authStateProvider] a *permanent* value-less `AsyncError` — under the
///     old check that made this function return `null` on every route,
///     forever, i.e. the wall failed OPEN. `isLoading` is `false` once the
///     stream has settled to an error, so that case falls through to #4
///     instead.
///  4. [AsyncValue.hasError] — the auth stream is in an error state. This
///     covers TWO materially different situations and must NOT treat them
///     alike (the offline-reliability audit, 2026-07-30):
///
///       * **No session at all** ([hasKnownLocalSessionProvider] false):
///         Supabase never initialized, or nobody has ever signed in on this
///         device. Treated as UNAUTHENTICATED — redirect to
///         [webAuthGateSignInPath]. Fail closed. This is what the original
///         version of this comment was written against.
///       * **Session present, backend unreachable**
///         ([hasKnownLocalSessionProvider] true): gotrue's 10s refresh
///         ticker throws `AuthRetryableFetchException` while offline and
///         forwards it onto `onAuthStateChange`, WITHOUT signing anyone out —
///         the in-memory session and the persisted localStorage token both
///         survive. That is signed-in-OFFLINE, so pass through (`null`).
///         Bouncing this user to `/account` ejects them to a screen whose
///         only affordance (send a magic link / Google OAuth) needs the very
///         network that just failed, i.e. a dead end. Decided by
///         [hasKnownLocalSessionProvider], which is a purely local read —
///         live-session uid, else the persisted `lastKnownUid` — so this
///         decision NEVER makes a network call.
///
///     Read with `container.read` rather than watched: `lastKnownUid` only
///     ever changes alongside an [authStateProvider] emission, and
///     [_ensureAuthRefreshWired] already turns every such emission into a
///     [GoRouter.refresh], so there is nothing a second listener would add.
///  5. Otherwise a resolved value is present: signed-in passes through
///     untouched (`null`); signed-out redirects to [webAuthGateSignInPath].
///     An explicit signed-out EMISSION is authoritative (the user signed
///     out, or the session expired hard) and is never softened by
///     [hasKnownLocalSessionProvider] — only the ambiguous error case is.
FutureOr<String?> _webAuthGateRedirect(
  BuildContext context,
  GoRouterState state,
) {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(webAuthGateEnabledProvider)) return null;

  _ensureAuthRefreshWired(container);

  if (state.matchedLocation == webAuthGateSignInPath) return null;

  final authAsync = container.read(authStateProvider);

  if (authAsync.isLoading && !authAsync.hasValue) return null;

  if (authAsync.hasError) {
    return container.read(hasKnownLocalSessionProvider)
        ? null
        : webAuthGateSignInPath;
  }

  return authAsync.value!.isSignedIn ? null : webAuthGateSignInPath;
}

/// Wires a ONE-TIME [authStateProvider] listener onto [container] that calls
/// [GoRouter.refresh] on every emission, so [_webAuthGateRedirect] gets
/// re-evaluated for the CURRENT location the moment the auth stream actually
/// resolves (e.g. loading -> signed-out must then bounce to
/// [webAuthGateSignInPath], but [_webAuthGateRedirect] itself only runs on
/// navigation attempts, never on a bare state change by itself — `refresh()`
/// is what turns "state changed" into "re-run the redirect check"). Guarded
/// by [_authRefreshWired] since every navigation re-invokes
/// [_webAuthGateRedirect] against the same container, which would otherwise
/// pile up a duplicate listener per navigation.
void _ensureAuthRefreshWired(ProviderContainer container) {
  if (_authRefreshWired[container] != null) return;
  _authRefreshWired[container] = true;
  container.listen(
    authStateProvider,
    (previous, next) => appRouter.refresh(),
  );
}

final appRouter = GoRouter(
  redirect: _webAuthGateRedirect,
  routerNeglect: isSafariBrowser(),
  routes: [
    // The persistent bottom-nav shell (see `nav_shell.dart`'s `NavShell`):
    // three `IndexedStack` branches — Topos (home, index 0) / Map (index 1)
    // / Feed (index 2) — each preserving its own navigator/scroll state
    // across tab switches. Every route BELOW this one is a top-level
    // sibling instead, so it builds on the ROOT navigator and appears
    // full-screen, above the bottom bar (see `NavShell`'s doc).
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          NavShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const ToposScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/map',
              builder: (context, state) => CommunityMapScreen(
                focusWallId: state.uri.queryParameters['focus'],
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/feed',
              builder: (context, state) => const CommunityFeedScreen(),
            ),
          ],
        ),
      ],
    ),
    // The legacy Community discovery path — see [communityRedirectTarget]'s
    // doc. Kept alive (rather than removed) since it's still built by
    // `topos_screen.dart`'s "Show on map" action and any old bookmark/deep
    // link.
    GoRoute(
      path: '/community',
      redirect: (context, state) =>
          communityRedirectTarget(state.uri.queryParameters),
    ),
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountScreen(),
    ),
    // A shared topo's read-only detail — reached by `context.push`ing this
    // exact path from the Feed/Map screens' rows/markers. Full-screen, above
    // the bottom nav (see `NavShell`'s doc) — a focused, single-topo view is
    // not one of the three persistent tabs.
    GoRoute(
      path: '/community/topo/:wallId',
      builder: (context, state) =>
          CommunityTopoDetailScreen(wallId: state.pathParameters['wallId']!),
    ),
    // A shared ascent log's read-only detail (Feature #12, public opt-in
    // ascent logs) — see AscentDetailScreen's class doc.
    GoRoute(
      path: '/community/ascent/:id',
      builder: (context, state) =>
          AscentDetailScreen(ascentId: state.pathParameters['id']!),
    ),
    // The personal ascent Logbook (see LogbookScreen's class doc).
    GoRoute(
      path: '/logbook',
      builder: (context, state) => const LogbookScreen(),
    ),
    GoRoute(path: '/areas', builder: (context, state) => const AreasScreen()),
    GoRoute(
      path: '/areas/:areaId/sectors',
      builder: (context, state) => SectorsScreen(
        areaId: state.pathParameters['areaId']!,
        areaName: state.extra as String?,
      ),
    ),
    GoRoute(
      path: '/sectors/:sectorId/walls',
      builder: (context, state) => WallsScreen(
        sectorId: state.pathParameters['sectorId']!,
        sectorName: state.extra as String?,
      ),
    ),
    // The wall-detail route hosts the real topo canvas, bound to the
    // navigated wall (see TopoCanvasScreen.wallId). An optional `?readonly=1`
    // query param (used by community/nearby entry points — see
    // `topos_row.dart`'s `_CommunityProximityRow` and
    // `community_map_screen.dart`'s community marker) renders the SAME
    // canvas in `readOnly` mode instead of routing to the social/likes-first
    // `CommunityTopoDetailScreen`; absent (or any non-`1` value) keeps the
    // existing editable default so own-topo navigation is unaffected.
    GoRoute(
      path: '/walls/:wallId',
      builder: (context, state) => TopoCanvasScreen(
        wallId: state.pathParameters['wallId']!,
        readOnly: state.uri.queryParameters['readonly'] == '1',
      ),
    ),
    // The AR alignment view for a wall — see ArScreen's class doc for the
    // native-camera-vs-overlay platform split.
    GoRoute(
      path: '/walls/:wallId/ar',
      builder: (context, state) =>
          ArScreen(wallId: state.pathParameters['wallId']!),
    ),
  ],
);
