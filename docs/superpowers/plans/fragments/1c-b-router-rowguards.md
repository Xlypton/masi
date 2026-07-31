# Fragment 1c-B — web router stops failing closed · guarded mutations verify row count

Half B of spec §1c (`docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`), fixing the
audit's **L4** (silent write loss) and the **"Web: the user is ejected to a sign-in screen they cannot
use offline"** gap.

**Consumes (produced by fragment 1c-A, treat as existing):** `lastKnownUidProvider` (`String?`),
`effectiveUidProvider`, `hasKnownLocalSessionProvider` (`Provider<bool>`, `true` when
`effectiveUid != null`). This fragment reads **only** `hasKnownLocalSessionProvider`, in two places:
`_webAuthGateRedirect` (Task 1) and `libraryCrudRepositoryProvider` (Task 2).

**Out of scope here:** `lastKnownUid` persistence, `effectiveUid` unification, `toposProvider` (all 1c-A).

**Public symbols this fragment adds** (nothing else becomes public):
- `LibraryWriteLostException` (`operation`, `rowId`, `reason`, `toString()`)
- `enum LibraryWriteLostReason { ownerIdentityUnknown, unexpectedZeroRows }`
- `LibraryCrudRepository({..., bool Function() hasKnownSession = _noSession})` — new optional named param

**Sequencing / file-sharing (read before dispatching):**
- Task 1 is file-disjoint from Tasks 2–4 → may run in parallel with them.
- **Tasks 2 and 3 both edit `lib/features/library/data/library_crud_repository.dart` → strictly
  sequential, 2 then 3.** Task 4 edits only presentation files but depends on Task 2's exception type.
- **Task 2 edits `lib/features/library/application/library_providers.dart`, which fragment 1c-A also
  edits (`toposProvider`, `currentUid:` → `effectiveUid`).** Run 1c-A's provider task and this Task 2
  sequentially, never in parallel.

Baseline to keep green: `flutter analyze` 0 issues, `flutter test` 1576 passing (this fragment adds 13
tests → 1589).

---

### Task 1: Web auth wall treats "session present, backend unreachable" as signed-in-offline

**Files:**
- Modify `lib/app/router.dart:83-135` (the "Order of checks" doc block `:83-116`, and
  `_webAuthGateRedirect`'s body `:117-135` — the fail-closed `hasError` line is `:132`)
- Modify `lib/app/router.dart:9` region? **No** — `auth_providers.dart` is already imported at `:9`;
  `hasKnownLocalSessionProvider` lives there, so no new import.
- Test `test/app/router_test.dart` — modify `_FakeAuthRepository` (add one named ctor after `:105`),
  `_makeGateContainerFromRepo` (`:150-167`, add `extraOverrides`), and add 2 tests to the
  `'web auth wall: …'` group (`:614-752`)

**Interfaces:**
- Consumes: `hasKnownLocalSessionProvider` — `Provider<bool>`, read via
  `container.read(hasKnownLocalSessionProvider)` (no `watch`; `_webAuthGateRedirect` is a plain
  top-level function with no `Ref`).
- Produces: no new public symbol. `_webAuthGateRedirect`'s signature is unchanged:
  `FutureOr<String?> _webAuthGateRedirect(BuildContext context, GoRouterState state)`

- [ ] **Step 1: Write the failing test**

In `test/app/router_test.dart`, add this named constructor to `_FakeAuthRepository` immediately after
the `_FakeAuthRepository.erroring` constructor (i.e. after `:105`):

```dart
  /// Errors on [authStateChanges] while [currentSession] STILL reports a
  /// live signed-in session with a uid — the real offline shape (audit
  /// "Auth / UI gaps"): gotrue's 10s refresh ticker throws
  /// `AuthRetryableFetchException` and pushes it onto `onAuthStateChange`,
  /// but it does NOT sign the user out, so the in-memory session (and the
  /// persisted localStorage token) survive. Distinct from
  /// [_FakeAuthRepository.erroring], whose `currentSession` is signed OUT
  /// (the `Supabase.initialize()`-failed shape).
  _FakeAuthRepository.erroringWithLiveSession(
    Object error, {
    String email = 'climber@example.com',
    String uid = 'uid-1',
  }) : _current = AuthSessionState.signedIn(email, uid: uid) {
    _controller.addError(error);
  }
```

Replace `_makeGateContainerFromRepo` (`:150-167`) with a version that accepts extra overrides:

```dart
ProviderContainer _makeGateContainerFromRepo(
  _FakeAuthRepository repo, {
  required bool gateEnabled,
  List<Override> extraOverrides = const [],
}) {
  addTearDown(repo.dispose);
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      authRepositoryProvider.overrideWithValue(repo),
      webAuthGateEnabledProvider.overrideWithValue(gateEnabled),
      ...extraOverrides,
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}
```

Add these two tests inside the `'web auth wall: _webAuthGateRedirect gates every route behind sign-in
on web, and is a total no-op on native'` group (after the existing errored/fails-closed test that ends
at `:713`):

```dart
    testWidgets(
      'gate enabled + auth stream ERRORED but a known local session exists '
      '(offline token-refresh failure): does NOT redirect — signed-in-offline '
      'is not signed-out, and /account is unusable without a network anyway',
      (tester) async {
        final container = _makeGateContainerFromRepo(
          _FakeAuthRepository.erroring(
            StateError('AuthRetryableFetchException (offline)'),
          ),
          gateEnabled: true,
          extraOverrides: [
            hasKnownLocalSessionProvider.overrideWithValue(true),
          ],
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
        expect(find.byType(AccountScreen), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + auth stream errored while currentSession still carries '
      'a live uid: the real wiring (no hasKnownLocalSessionProvider override) '
      'also lets the user stay — the uid door must survive an AsyncError',
      (tester) async {
        final container = _makeGateContainerFromRepo(
          _FakeAuthRepository.erroringWithLiveSession(
            StateError('AuthRetryableFetchException (offline)'),
          ),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byType(AccountScreen), findsNothing);
      },
    );
```

Add the import of `hasKnownLocalSessionProvider` — it lives in the already-imported
`package:masi/features/account/application/auth_providers.dart` (`test/app/router_test.dart:7`), so no
new import line is needed.

- [ ] **Step 2: Run it, see it fail**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/router_test.dart
```

Expected: both new tests fail with
`Expected: exactly one matching candidate / Actual: _WidgetTypeFinder:<Found 0 widgets with type "ToposScreen">`
— `_webAuthGateRedirect` still returns `webAuthGateSignInPath` at `router.dart:132` for any `hasError`,
so `AccountScreen` renders instead. (If 1c-A has not landed yet, the failure is instead
`Undefined name 'hasKnownLocalSessionProvider'` — that is the same signal: this task blocks on 1c-A.)

- [ ] **Step 3: Minimal implementation**

In `lib/app/router.dart`, replace the doc block's cases #4/#5 and the fail-closed preamble
(`:83-116`) plus the body (`:117-135`) with:

```dart
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
///       * **No session at all** (`hasKnownLocalSessionProvider` false):
///         Supabase never initialized, or nobody has ever signed in on this
///         device. Treated as UNAUTHENTICATED — redirect to
///         [webAuthGateSignInPath]. Fail closed. This is what the original
///         version of this comment was written against.
///       * **Session present, backend unreachable**
///         (`hasKnownLocalSessionProvider` true): gotrue's 10s refresh
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
```

- [ ] **Step 4: Run it, see it pass**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/router_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add lib/app/router.dart test/app/router_test.dart
git commit -m "$(cat <<'EOF'
fix(web): treat errored auth + known local session as signed-in-offline

The web auth wall returned the sign-in path for any `authStateProvider`
error, so gotrue's offline token-refresh failure (which does NOT sign the
user out) ejected a signed-in PWA user to /account — a screen whose only
affordances need the network that just failed. The gate now consults
`hasKnownLocalSessionProvider` (a purely local read: live uid, else the
persisted lastKnownUid); only "no session at all" still fails closed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

**Assertions:**
1. `flutter test test/app/router_test.dart` green, including the pre-existing
   `'gate enabled + auth state errored … the wall fails CLOSED, never open'` test (`:692`) — it uses
   `_FakeAuthRepository.erroring`, whose `currentSession` is `signedOut()` with a null uid, so
   `hasKnownLocalSessionProvider` is false and it still redirects. **No existing router test changes.**
2. Errored stream + `hasKnownLocalSessionProvider` true → `ToposScreen` renders, `AccountScreen` does not.
3. Errored stream + live `currentSession.uid` and NO override → also no redirect (proves 1c-A's uid door
   is sourced synchronously from `authRepository.currentSession`, not from `authStateProvider.asData`).
4. `grep -c 'return webAuthGateSignInPath' lib/app/router.dart` is 3 (case 4's no-session branch, case
   5's signed-out branch, and no others); `grep -n 'hasError' lib/app/router.dart` shows exactly one hit
   and it is not an unconditional return.
5. The `router.dart:111-113` comment text "treated as UNAUTHENTICATED, not as \"unknown, let them
   through\"" no longer exists unqualified — the doc now names both error situations
   (`grep -c 'Session present, backend unreachable' lib/app/router.dart` is 1).
6. `flutter analyze` 0 issues; no `kIsWeb` introduced in `router.dart`.

---

### Task 2: Row-count-verified guard helper + the 6 single-row guarded UPDATEs

**Files:**
- Modify `lib/features/library/data/library_crud_repository.dart`:
  new top-level `LibraryWriteLostReason` + `LibraryWriteLostException` (insert after the
  `_unsetOwnerUid` const, `:44`); new `hasKnownSession` field/param (`:56-72`); new
  `_GuardOutcome`/`_classifyGuardTarget`/`_guardedWrite` (insert after `_ownOrUnowned`, `:87-92`);
  rewrite `renameArea` (`:173-184`), `renameSector` (`:275-286`), `renameWall` (`:366-376`),
  `setWallCoordinates` (`:429-449`), `moveWall` (`:470-493`), `moveSector` (`:506-529`)
- Modify `lib/features/library/application/library_providers.dart:19-26` (add the `hasKnownSession:`
  wiring) — **shared file with fragment 1c-A, see Sequencing above**
- Test `test/features/library/data/library_crud_repository_test.dart` — add one group at the end of
  `main()` (file currently ends the last group before the closing `}`); reuse the file's existing
  `setUp` `db` / `repo` (`:16-24`) and its `LibraryCrudRepository(db, nowMs: () => …, currentUid: …)`
  construction idiom (as at `:2444-2456`)

**Interfaces:**
- Produces:
  - `enum LibraryWriteLostReason { ownerIdentityUnknown, unexpectedZeroRows }`
  - `class LibraryWriteLostException implements Exception` —
    `const LibraryWriteLostException({required String operation, required String rowId, required LibraryWriteLostReason reason})`
  - `LibraryCrudRepository(db, {required int Function() nowMs, PhotoFiles? photoFiles, String? Function() currentUid = _noUid, bool Function() hasKnownSession = _noSession})`
- Consumes: `hasKnownLocalSessionProvider` (`Provider<bool>`) at the provider wiring only.
- Unchanged: every mutation keeps its `Future<void>` signature. Failure is a **throw**, not a return
  value — 12 of the 14 call sites are `await repo.x(...)` inside UI handlers, so a return code would be
  discarded exactly like the row count is today.

- [ ] **Step 1: Write the failing test**

Append this group inside `main()` in `test/features/library/data/library_crud_repository_test.dart`:

```dart
  group('L4: a guarded mutation that matches 0 rows never reports success', () {
    // The L4 state (audit 2026-07-30): a captive portal makes gotrue throw a
    // non-retryable AuthUnknownException -> `_removeSession()` -> the uid
    // door returns null while the device still HAS a local session. Every
    // `_ownOrUnowned` predicate then collapses to `ownerId IS NULL`, matches
    // 0 of the caller's own owner-stamped rows, and the pre-fix code
    // reported success.
    LibraryCrudRepository lostUidRepo() => LibraryCrudRepository(
      db,
      nowMs: () => 2000,
      currentUid: () => null,
      hasKnownSession: () => true,
    );

    test(
      'renameArea/renameSector/renameWall throw ownerIdentityUnknown and '
      'leave the rows untouched',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
          hasKnownSession: () => true,
        );
        final area = await owned.createArea('Area');
        final sector = await owned.createSector(area.id, 'Sector');
        final wall = await owned.createWall(sector.id, 'Wall');

        final lost = lostUidRepo();

        await expectLater(
          lost.renameArea(area.id, 'Hijacked Area'),
          throwsA(
            isA<LibraryWriteLostException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  LibraryWriteLostReason.ownerIdentityUnknown,
                )
                .having((e) => e.rowId, 'rowId', area.id),
          ),
        );
        await expectLater(
          lost.renameSector(sector.id, 'Hijacked Sector'),
          throwsA(isA<LibraryWriteLostException>()),
        );
        await expectLater(
          lost.renameWall(wall.id, 'Hijacked Wall'),
          throwsA(isA<LibraryWriteLostException>()),
        );

        final areaRow = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        final sectorRow = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        final wallRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(areaRow.name, 'Area');
        expect(sectorRow.name, 'Sector');
        expect(wallRow.name, 'Wall');
      },
    );

    test(
      'setWallCoordinates/moveWall/moveSector throw ownerIdentityUnknown '
      'and leave the rows untouched',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
          hasKnownSession: () => true,
        );
        final area = await owned.createArea('Area');
        final destArea = await owned.createArea('Dest Area');
        final sector = await owned.createSector(area.id, 'Sector');
        final destSector = await owned.createSector(area.id, 'Dest Sector');
        final wall = await owned.createWall(sector.id, 'Wall');

        final lost = lostUidRepo();

        await expectLater(
          lost.setWallCoordinates(wall.id, 47.4979, 19.0402),
          throwsA(isA<LibraryWriteLostException>()),
        );
        await expectLater(
          lost.moveWall(wall.id, destSector.id),
          throwsA(isA<LibraryWriteLostException>()),
        );
        await expectLater(
          lost.moveSector(sector.id, destArea.id),
          throwsA(isA<LibraryWriteLostException>()),
        );

        final wallRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(wallRow.latitude, isNull);
        expect(wallRow.longitude, isNull);
        expect(wallRow.sectorId, sector.id);
        expect(wallRow.updatedAt, 1000);
        final sectorRow = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        expect(sectorRow.areaId, area.id);
      },
    );

    test(
      'a device with NO known session keeps the documented silent no-op on a '
      'foreign/owner-stamped row (a genuinely signed-out device must not '
      'start throwing)',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'someone-else',
        );
        final area = await owned.createArea('Their Area');

        // `repo` from setUp: currentUid always null, hasKnownSession default
        // false — the never-signed-in device.
        await repo.renameArea(area.id, 'Hijacked');

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        expect(row.name, 'Their Area');
      },
    );

    test(
      'an UNOWNED row stays writable with a lost uid — only owner-stamped '
      'rows are ambiguous, so the guard must not over-throw',
      () async {
        final area = await repo.createArea('Unowned Area');

        final lost = lostUidRepo();
        await lost.renameArea(area.id, 'Renamed Unowned');

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        expect(row.name, 'Renamed Unowned');
      },
    );

    test(
      'a nonexistent / already soft-deleted target stays a silent no-op even '
      'with a lost uid (absent is not ambiguous)',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
          hasKnownSession: () => true,
        );
        final area = await owned.createArea('Area');
        await owned.softDeleteArea(area.id);

        final lost = lostUidRepo();
        await lost.renameArea('no-such-area-id', 'Nope');
        await lost.renameArea(area.id, 'Also Nope');

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        expect(row.name, 'Area');
      },
    );
  });
```

- [ ] **Step 2: Run it, see it fail**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/library_crud_repository_test.dart
```

Expected: compile failure —
`Error: No named parameter with the name 'hasKnownSession'.` and
`Error: Undefined name 'LibraryWriteLostException'.` /
`Error: Undefined name 'LibraryWriteLostReason'.`
(This is the correct TDD signal for a new API: the assertion the test encodes — a throw where the
pre-fix code silently updated 0 rows and returned normally — cannot be expressed without it.)

- [ ] **Step 3: Minimal implementation**

**3a.** In `lib/features/library/data/library_crud_repository.dart`, insert after the `_unsetOwnerUid`
const (`:44`):

```dart
/// Why an `_ownOrUnowned`-guarded mutation refused to report success — see
/// [LibraryWriteLostException].
enum LibraryWriteLostReason {
  /// The write ran with NO uid while this device DOES have a known local
  /// session ([LibraryCrudRepository.hasKnownSession] is `true`), so the
  /// ownership predicate collapsed to `ownerId IS NULL` and could not match
  /// the caller's own owner-stamped rows. Audit item L4 (2026-07-30): this
  /// used to update 0 rows and report success — a rename/move/GPS-stamp/
  /// delete silently discarded.
  ownerIdentityUnknown,

  /// The target row is present, live and own-or-unowned under the CURRENT
  /// uid, yet the UPDATE still matched 0 rows — an invariant violation (e.g.
  /// ownership changed underneath the statement). Never swallowed.
  unexpectedZeroRows,
}

/// Thrown by a guarded [LibraryCrudRepository] mutation that matched **no
/// rows** for a reason that is NOT one of the two documented no-ops (target
/// absent or soft-deleted; target genuinely foreign-owned under a known
/// uid).
///
/// Exists because those UPDATEs previously discarded their affected-row
/// count: `.write(...)` returns the number of rows it touched and nothing
/// read it, so "I could not tell whose row this is" was indistinguishable
/// from "done". Callers surface this as a user-visible failure (see
/// `crud_list_scaffold.dart`'s `_runGuarded` and `topos_row.dart`'s).
class LibraryWriteLostException implements Exception {
  const LibraryWriteLostException({
    required this.operation,
    required this.rowId,
    required this.reason,
  });

  /// The repository method that failed, e.g. `'renameWall'` — for logs.
  final String operation;

  /// The primary key the mutation targeted.
  final String rowId;

  final LibraryWriteLostReason reason;

  @override
  String toString() =>
      'LibraryWriteLostException($operation, row $rowId, ${reason.name}): '
      'the write matched 0 rows and must not be reported as success';
}

/// Ownership verdict for one guarded-mutation target, resolved by
/// [LibraryCrudRepository._classifyGuardTarget].
enum _GuardOutcome {
  /// No such row, or it is already soft-deleted — a documented silent no-op.
  absent,

  /// Live and owned by a DIFFERENT, known uid — the deliberate Hole-B
  /// rejection, also a documented silent no-op.
  notOwned,

  /// Live and own-or-unowned: the mutation SHOULD have matched it.
  writable,

  /// Live and owner-stamped, but this device has no uid to compare against
  /// while it does have a known local session — ownership is unknowable, so
  /// neither "yours" nor "theirs" may be asserted. Audit item L4.
  identityUnknown,
}
```

**3b.** Constructor + field (`:56-72`). Replace the constructor and add the field/default next to
`currentUid`'s:

```dart
  LibraryCrudRepository(
    this._db, {
    required this.nowMs,
    PhotoFiles? photoFiles,
    this.currentUid = _noUid,
    this.hasKnownSession = _noSession,
  }) : _photoFiles = photoFiles ?? PhotoFiles();
```

and, immediately after `static String? _noUid() => null;` (`:72`):

```dart
  /// Whether this device has a KNOWN local session — wired from
  /// `hasKnownLocalSessionProvider` (spec §1c: live-session uid, else the
  /// persisted `lastKnownUid`). Read only to DISAMBIGUATE a `null`
  /// [currentUid]:
  ///
  ///  * `currentUid() == null && !hasKnownSession()` — a device nobody has
  ///    ever signed in on. `ownerId IS NULL` is then the honest predicate and
  ///    an owner-stamped row genuinely is somebody else's: silent no-op,
  ///    exactly as before.
  ///  * `currentUid() == null && hasKnownSession()` — L4. We had an identity
  ///    and lost it; `ownerId IS NULL` is a LIE and the row may well be ours.
  ///    The mutation must fail loudly instead of updating 0 rows and
  ///    returning normally.
  ///
  /// Defaults to always-`false` so every existing constructor/test keeps its
  /// current behaviour unchanged.
  final bool Function() hasKnownSession;

  static bool _noSession() => false;
```

**3c.** Insert after `_ownOrUnowned` (`:87-92`):

```dart
  /// Classifies one guarded-mutation target with a single ownership-FREE
  /// re-read, run only when the guarded statement affected 0 rows (or, for
  /// the cascade entry points, before the cascade starts). Reads `ownerId` +
  /// `deletedAt` by primary key — one indexed row, no join.
  Future<_GuardOutcome> _classifyGuardTarget({
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
    required String id,
  }) async {
    final query = _db.selectOnly(table)
      ..addColumns([ownerColumn, deletedAtColumn])
      ..where(idColumn.equals(id))
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return _GuardOutcome.absent;
    if (row.read(deletedAtColumn) != null) return _GuardOutcome.absent;

    final owner = row.read(ownerColumn);
    final uid = currentUid();
    if (uid == null) {
      // An unowned row matches `ownerId IS NULL` regardless of who we are,
      // so it is never ambiguous.
      if (owner == null) return _GuardOutcome.writable;
      return hasKnownSession()
          ? _GuardOutcome.identityUnknown
          : _GuardOutcome.notOwned;
    }
    return (owner == null || owner == uid)
        ? _GuardOutcome.writable
        : _GuardOutcome.notOwned;
  }

  /// Awaits [write] — an already-issued `_ownOrUnowned`-guarded UPDATE — and
  /// VERIFIES its affected-row count instead of discarding it. A 0-row result
  /// stays silent only for the two documented no-ops ([_GuardOutcome.absent],
  /// [_GuardOutcome.notOwned]); anything else throws
  /// [LibraryWriteLostException].
  ///
  /// Every guarded single-row mutation routes through this ONE helper rather
  /// than growing its own ad-hoc row-count check, so the "when is 0 rows OK"
  /// policy lives in exactly one place.
  Future<void> _guardedWrite({
    required String operation,
    required String id,
    required Future<int> write,
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
  }) async {
    final updated = await write;
    if (updated > 0) return;
    final outcome = await _classifyGuardTarget(
      table: table,
      idColumn: idColumn,
      ownerColumn: ownerColumn,
      deletedAtColumn: deletedAtColumn,
      id: id,
    );
    switch (outcome) {
      case _GuardOutcome.absent:
      case _GuardOutcome.notOwned:
        return;
      case _GuardOutcome.identityUnknown:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.ownerIdentityUnknown,
        );
      case _GuardOutcome.writable:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.unexpectedZeroRows,
        );
    }
  }
```

**3d.** Rewrite the six single-row mutations. `renameArea` (`:173-184`):

```dart
  Future<void> renameArea(String id, String name) async {
    _rejectReservedName(name);
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameArea',
      id: id,
      table: _db.areas,
      idColumn: _db.areas.id,
      ownerColumn: _db.areas.ownerId,
      deletedAtColumn: _db.areas.deletedAt,
      write: (_db.update(_db.areas)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(db.AreasCompanion(name: Value(name), updatedAt: Value(now))),
    );
  }
```

`renameSector` (`:275-286`):

```dart
  Future<void> renameSector(String id, String name) async {
    _rejectReservedName(name);
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameSector',
      id: id,
      table: _db.sectors,
      idColumn: _db.sectors.id,
      ownerColumn: _db.sectors.ownerId,
      deletedAtColumn: _db.sectors.deletedAt,
      write: (_db.update(_db.sectors)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(db.SectorsCompanion(name: Value(name), updatedAt: Value(now))),
    );
  }
```

`renameWall` (`:366-376`):

```dart
  Future<void> renameWall(String id, String name) async {
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameWall',
      id: id,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
      write: (_db.update(_db.walls)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(db.WallsCompanion(name: Value(name), updatedAt: Value(now))),
    );
  }
```

`setWallCoordinates` — keep the whole doc comment (`:418-428`) and replace only the body (`:429-449`):

```dart
  Future<void> setWallCoordinates(
    String wallId,
    double latitude,
    double longitude,
  ) async {
    final now = nowMs();
    await _guardedWrite(
      operation: 'setWallCoordinates',
      id: wallId,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
      write: (_db.update(_db.walls)..where(
            (t) =>
                t.id.equals(wallId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.WallsCompanion(
              latitude: Value(latitude),
              longitude: Value(longitude),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }
```

`moveWall` — keep the doc (`:451-469`), replace the body (`:470-493`):

```dart
  Future<void> moveWall(String wallId, String newSectorId) {
    return _db.transaction(() async {
      final now = nowMs();
      final sortOrder = await _nextSortOrder(
        table: _db.walls,
        sortOrderColumn: _db.walls.sortOrder,
        scope: _db.walls.sectorId.equals(newSectorId),
      );
      await _guardedWrite(
        operation: 'moveWall',
        id: wallId,
        table: _db.walls,
        idColumn: _db.walls.id,
        ownerColumn: _db.walls.ownerId,
        deletedAtColumn: _db.walls.deletedAt,
        write: (_db.update(_db.walls)..where(
              (t) =>
                  t.id.equals(wallId) &
                  t.deletedAt.isNull() &
                  _ownOrUnowned(t.ownerId),
            ))
            .write(
              db.WallsCompanion(
                sectorId: Value(newSectorId),
                sortOrder: Value(sortOrder),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            ),
      );
    });
  }
```

`moveSector` — keep the doc (`:495-505`), replace the body (`:506-529`):

```dart
  Future<void> moveSector(String sectorId, String newAreaId) {
    return _db.transaction(() async {
      final now = nowMs();
      final sortOrder = await _nextSortOrder(
        table: _db.sectors,
        sortOrderColumn: _db.sectors.sortOrder,
        scope: _db.sectors.areaId.equals(newAreaId),
      );
      await _guardedWrite(
        operation: 'moveSector',
        id: sectorId,
        table: _db.sectors,
        idColumn: _db.sectors.id,
        ownerColumn: _db.sectors.ownerId,
        deletedAtColumn: _db.sectors.deletedAt,
        write: (_db.update(_db.sectors)..where(
              (t) =>
                  t.id.equals(sectorId) &
                  t.deletedAt.isNull() &
                  _ownOrUnowned(t.ownerId),
            ))
            .write(
              db.SectorsCompanion(
                areaId: Value(newAreaId),
                sortOrder: Value(sortOrder),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            ),
      );
    });
  }
```

Note both `move*` methods throw from **inside** `_db.transaction`, so the `_nextSortOrder` read and any
partial work roll back — nothing is half-applied.

**3e.** Provider wiring — `lib/features/library/application/library_providers.dart:19-26`:

```dart
final libraryCrudRepositoryProvider = Provider<LibraryCrudRepository>(
  (ref) => LibraryCrudRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
    // Disambiguates a null `currentUid` (see `hasKnownSession`'s doc): read
    // lazily per call, like `currentUid` itself, so this provider never
    // rebuilds on an auth change and no guarded mutation freezes a stale
    // answer into itself.
    hasKnownSession: () => ref.read(hasKnownLocalSessionProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);
```

(`hasKnownLocalSessionProvider` comes from `../../account/application/auth_providers.dart`, already
imported at `:6`.)

- [ ] **Step 4: Run it, see it pass**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/library_crud_repository_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/library/data/library_crud_repository.dart \
        lib/features/library/application/library_providers.dart \
        test/features/library/data/library_crud_repository_test.dart
git commit -m "$(cat <<'EOF'
fix(library): verify affected row count on owner-guarded mutations

Audit L4: rename/move/GPS-stamp UPDATEs discarded `.write()`'s row count,
so when the uid door returned null unexpectedly the ownership predicate
collapsed to `ownerId IS NULL`, matched 0 of the caller's own rows and
reported success — silent write loss. One `_guardedWrite` helper now
classifies a 0-row result: absent/foreign stay silent no-ops, an
unknowable-identity or should-have-matched row throws
LibraryWriteLostException. `hasKnownSession` (from
hasKnownLocalSessionProvider) is what distinguishes "never signed in" from
"lost the uid we had".

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

**Assertions:**
1. The 5 new tests pass; full `flutter test` is 1576 + 5 = **1581 passing, 0 failing**.
2. **No existing test is modified.** Specifically re-run and confirm still green, unchanged:
   - `library_crud_repository_test.dart:2439-2519` (foreign-owned wall stays uneditable — `myRepo` has
     `currentUid: () => 'my-uid'`, non-null → `_GuardOutcome.notOwned` → silent, as before)
   - `:2521-2565` (`setWallCoordinates`/`publishTopo`/`moveWall` on a foreign wall are silent no-ops)
   - `:2257` (nonexistent wallId is a silent no-op) and `:2389`/`:2411` (R5a/R5b: moving a soft-deleted
     wall/sector is a no-op → classified `absent` → silent)
   - `:1691-1780` (ownerId stamping / signed-out inserts) and `:1900-2050` (`claimOwnership`)
   - `test/features/library/data/photo_ownership_test.dart`,
     `test/features/library/presentation/{areas_screen,sectors_walls_screen,topos_screen}_test.dart`
3. Behaviour-change surface is exactly: `currentUid() == null && hasKnownSession() == true` against a
   live owner-stamped row. Every widget/unit test either injects a non-null uid or leaves
   `hasKnownSession` at its `false` default, which is why nothing else moves.
4. `grep -c '_guardedWrite(' lib/features/library/data/library_crud_repository.dart` is 7 (1 definition
   + 6 call sites); `grep -c 'LibraryWriteLostReason\.' …` is 4 (2 enum decls used at 2 throw sites).
5. No guarded mutation's public signature changed: `grep -n 'Future<void> rename\|Future<void> move\|Future<void> setWallCoordinates' …`
   still shows `Future<void>`.
6. `flutter analyze` 0 issues (in particular the `switch` over `_GuardOutcome` is exhaustive — no
   `default`, so a future enum value is a compile error, not a silent fallthrough).

---

### Task 3: The four check-then-act cascade guards + the two cascade UPDATEs

**Files:**
- Modify `lib/features/library/data/library_crud_repository.dart`: delete `_isOwnOrUnownedWall`
  (`:101-108`), `_isOwnOrUnownedArea` (`:114-121`), `_isOwnOrUnownedSector` (`:125-132`) and add
  `_guardedCascadeAllowed` in their place; rewrite the bail lines in `softDeleteArea` (`:204`),
  `softDeleteSector` (`:302`), `softDeleteWall` (`:395`), `_setWallVisibility` (`:536`); route the
  cascade's own UPDATEs through `_guardedWrite` — `_cascadeSoftDeleteAreaSubtree` (`:1280-1286`) and
  `_cascadeSoftDeleteSectorSubtree` (`:1303-1311`)
- Test `test/features/library/data/library_crud_repository_test.dart` — extend the group added in
  Task 2

**Interfaces:** Consumes Task 2's `_classifyGuardTarget`, `_guardedWrite`, `_GuardOutcome`,
`LibraryWriteLostException`. Produces no new public symbol. `softDeleteArea`/`softDeleteSector`/
`softDeleteWall`/`publishTopo`/`unpublishTopo` keep `Future<void>`.

- [ ] **Step 1: Write the failing test**

Append inside the `'L4: a guarded mutation that matches 0 rows never reports success'` group:

```dart
    test(
      'softDeleteArea/softDeleteSector/softDeleteWall with a lost uid throw '
      'and roll the whole cascade back (no half-deleted subtree)',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
          hasKnownSession: () => true,
        );
        final area = await owned.createArea('Area');
        final sector = await owned.createSector(area.id, 'Sector');
        final wall = await owned.createWall(sector.id, 'Wall');

        final lost = lostUidRepo();

        await expectLater(
          lost.softDeleteWall(wall.id),
          throwsA(
            isA<LibraryWriteLostException>().having(
              (e) => e.reason,
              'reason',
              LibraryWriteLostReason.ownerIdentityUnknown,
            ),
          ),
        );
        await expectLater(
          lost.softDeleteSector(sector.id),
          throwsA(isA<LibraryWriteLostException>()),
        );
        await expectLater(
          lost.softDeleteArea(area.id),
          throwsA(isA<LibraryWriteLostException>()),
        );

        final wallRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        final sectorRow = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        final areaRow = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        expect(wallRow.deletedAt, isNull);
        expect(sectorRow.deletedAt, isNull);
        expect(areaRow.deletedAt, isNull);
      },
    );

    test(
      'publishTopo/unpublishTopo with a lost uid throw and leave the wall '
      'plus its photos/routes untouched',
      () async {
        final owned = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
          hasKnownSession: () => true,
        );
        final area = await owned.createArea('Area');
        final sector = await owned.createSector(area.id, 'Sector');
        final wall = await owned.createWall(sector.id, 'Wall');

        final lost = lostUidRepo();

        await expectLater(
          lost.publishTopo(wall.id),
          throwsA(isA<LibraryWriteLostException>()),
        );
        await expectLater(
          lost.unpublishTopo(wall.id),
          throwsA(isA<LibraryWriteLostException>()),
        );

        final row = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(row.visibility, 'private');
        expect(row.dirty, isFalse);
        expect(row.updatedAt, 1000);
      },
    );
```

- [ ] **Step 2: Run it, see it fail**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/library_crud_repository_test.dart
```

Expected failure (both tests):
`Expected: throws <Instance of 'LibraryWriteLostException'> / Actual: <Future> which: returned a Future that emitted no value`
— the `_isOwnOrUnowned*` probes currently return `false` for an owner-stamped row under a null uid and
the method bails with a silent `return`.

- [ ] **Step 3: Minimal implementation**

Replace `_isOwnOrUnownedWall` / `_isOwnOrUnownedArea` / `_isOwnOrUnownedSector` (`:94-132`, doc
comments included) with:

```dart
  /// Check-then-act half of the write-time ownership guard, for mutations
  /// that cascade beyond a single row (see [softDeleteArea]/
  /// [softDeleteSector]/[softDeleteWall]/[_setWallVisibility], whose inner
  /// per-row updates key off the parent id alone and so cannot carry the
  /// ownership predicate themselves).
  ///
  /// Replaces the three `_isOwnOrUnownedX` bool probes: `false` for the two
  /// documented silent no-ops (absent/soft-deleted target, or a genuinely
  /// foreign row under a known uid), `true` for an own-or-unowned target,
  /// and a [LibraryWriteLostException] when ownership is UNKNOWABLE (L4) —
  /// bailing quietly there is exactly the silent-write-loss bug.
  ///
  /// Called inside the caller's [db.AppDatabase.transaction], so a throw
  /// rolls the whole cascade back rather than leaving a subtree half
  /// soft-deleted.
  Future<bool> _guardedCascadeAllowed({
    required String operation,
    required String id,
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
  }) async {
    final outcome = await _classifyGuardTarget(
      table: table,
      idColumn: idColumn,
      ownerColumn: ownerColumn,
      deletedAtColumn: deletedAtColumn,
      id: id,
    );
    switch (outcome) {
      case _GuardOutcome.absent:
      case _GuardOutcome.notOwned:
        return false;
      case _GuardOutcome.identityUnknown:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.ownerIdentityUnknown,
        );
      case _GuardOutcome.writable:
        return true;
    }
  }
```

Then the four bail sites. `softDeleteArea` (`:204`):

```dart
      if (!await _guardedCascadeAllowed(
        operation: 'softDeleteArea',
        id: id,
        table: _db.areas,
        idColumn: _db.areas.id,
        ownerColumn: _db.areas.ownerId,
        deletedAtColumn: _db.areas.deletedAt,
      )) {
        return;
      }
```

`softDeleteSector` (`:302`) — identical with `operation: 'softDeleteSector'`, `table: _db.sectors`,
`idColumn: _db.sectors.id`, `ownerColumn: _db.sectors.ownerId`,
`deletedAtColumn: _db.sectors.deletedAt`.

`softDeleteWall` (`:395`) — identical with `operation: 'softDeleteWall'`, `table: _db.walls`,
`idColumn: _db.walls.id`, `ownerColumn: _db.walls.ownerId`, `deletedAtColumn: _db.walls.deletedAt`.

`_setWallVisibility` (`:536`):

```dart
    if (!await _guardedCascadeAllowed(
      operation: 'setWallVisibility',
      id: wallId,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
    )) {
      return;
    }
```

Finally route the two cascade UPDATEs through `_guardedWrite`.
`_cascadeSoftDeleteAreaSubtree`'s area update (`:1280-1286`):

```dart
    await _guardedWrite(
      operation: 'cascadeSoftDeleteArea',
      id: areaId,
      table: _db.areas,
      idColumn: _db.areas.id,
      ownerColumn: _db.areas.ownerId,
      deletedAtColumn: _db.areas.deletedAt,
      write: (_db.update(_db.areas)..where(
            (t) =>
                t.id.equals(areaId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.AreasCompanion(deletedAt: Value(now), updatedAt: Value(now)),
          ),
    );
```

`_cascadeSoftDeleteSectorSubtree`'s sector update (`:1303-1311`):

```dart
    await _guardedWrite(
      operation: 'cascadeSoftDeleteSector',
      id: sectorId,
      table: _db.sectors,
      idColumn: _db.sectors.id,
      ownerColumn: _db.sectors.ownerId,
      deletedAtColumn: _db.sectors.deletedAt,
      write: (_db.update(_db.sectors)..where(
            (t) =>
                t.id.equals(sectorId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.SectorsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
          ),
    );
```

**Deliberate narrowing to record in the commit body:** the old probes had NO `deletedAt.isNull()`
filter, so calling `softDeleteWall`/`_setWallVisibility` on an ALREADY soft-deleted own wall returned
`true` and re-ran the cascade; the new classifier reports `absent` and bails. Behaviour-equivalent —
every statement inside those cascades already filters `deletedAt.isNull()`, so the re-run wrote nothing
(covered by the existing `:2205` and `:2257` no-op tests).

- [ ] **Step 4: Run it, see it pass**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/library_crud_repository_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/library/data/library_crud_repository.dart \
        test/features/library/data/library_crud_repository_test.dart
git commit -m "$(cat <<'EOF'
fix(library): cascade guards fail loudly when ownership is unknowable

softDeleteArea/Sector/Wall and publish/unpublishTopo bailed with a silent
`return` whenever their `_isOwnOrUnownedX` probe came back false — which,
with an unexpectedly null uid, included the caller's OWN owner-stamped
rows (L4). The three probes collapse into one `_guardedCascadeAllowed`
sharing `_guardedWrite`'s classifier: absent/foreign still bail quietly,
unknowable identity throws. Throwing inside the existing transaction rolls
the cascade back, so no subtree is left half soft-deleted.

Behaviour narrowing: the old probes ignored `deletedAt`, so re-running a
cascade on an already-deleted wall was allowed (and wrote nothing, since
every inner statement filters deletedAt IS NULL). It now bails as absent.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

**Assertions:**
1. The 2 new tests pass; full `flutter test` is **1583 passing, 0 failing**; `flutter analyze` 0 issues.
2. `grep -c '_isOwnOrUnowned' lib/features/library/data/library_crud_repository.dart` is **0**
   (all three probes gone); `grep -c '_ownOrUnowned(' …` is 11 (1 definition + 10 predicate uses:
   6 single-row UPDATEs, 2 cascade UPDATEs, 2 cascade child selects).
3. Existing green-and-unmodified: `:2439-2519`, `:2521-2565` (foreign-owned no-ops),
   `:2205` (cascade no-ops), `:2257` (nonexistent wallId no-op), plus
   `test/features/library/data/photo_ownership_test.dart`.
4. After a thrown `softDeleteArea`, the area, its sector, its wall and the wall's photos/routes all
   still have `deletedAt == null` — the transaction rolled back (asserted directly by the new test).
5. `_guardedCascadeAllowed`'s `switch` is exhaustive with no `default`.

---

### Task 4: Callers surface a lost write to the user

**Files:**
- Modify `lib/features/library/presentation/crud_list_scaffold.dart:252-266` (`_handleCreate`,
  `_handleRename`), `:306-308` (`_handleDelete`'s confirm branch), plus one new private helper — this
  single file covers 6 of the call sites (rename + delete × Areas/Sectors/Walls, via
  `areas_screen.dart:36-41`, `sectors_screen.dart:44-49`, `walls_screen.dart:43-48`, which need **no
  edit**)
- Modify `lib/features/library/presentation/topos_row.dart`: `_handleRename` (`:292-305`),
  `_handlePublish`'s confirm branch (`:403-405`), `_handleUnpublish` (`:408-410`) and its call site in
  the menu switch (`:281`), `_handleDelete`'s confirm branch (`:499-501`), plus one new private helper
- Test `test/features/library/presentation/crud_list_scaffold_test.dart` (extend `_harness`, `:12-34`)
- Test `test/features/library/presentation/topos_screen_test.dart` (new throwing-repo subclass beside
  the existing `_ThrowingSetCoordinatesRepository`, `:320-331`)

**Interfaces:** Consumes `LibraryWriteLostException` (Task 2) only as "an exception"; both helpers catch
`Object` so a drift/IO failure surfaces identically. Produces no public symbol.

**Callers deliberately left alone:**
- `sectors_screen.dart:85-95` (`moveSector`) and `topos_row.dart:349-358` (`moveWall`) — already
  `try/catch` → `"Couldn't move — please try again"` SnackBar.
- `topos_row.dart:449-460` (`setWallCoordinates`) and `topo_canvas_screen.dart:479-491`
  (`_handleEditLocation`) — already `try/catch` → `"Couldn't save location — please try again"`.
- `topo_canvas_gps.dart:82-115` (`captureWallGpsFromPhoto`) — its outer `catch (_)` turns a throwing
  `setWallCoordinates` into `GpsCaptureResult.none`, i.e. the honest "no location captured" message
  instead of a false "Location saved from photo". Documented best-effort by design; unchanged.

- [ ] **Step 1: Write the failing test**

In `test/features/library/presentation/crud_list_scaffold_test.dart`, give `_harness` an injectable
`onRename` (add the parameter; keep the current default):

```dart
Widget _harness({
  required Future<void> Function(String item) onDelete,
  Future<void> Function(BuildContext context, String item)? onMove,
  Future<void> Function(String item, String newName)? onRename,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: CrudListScaffold<String>(
      title: 'Areas',
      entityKey: 'area',
      asyncItems: const AsyncValue.data(['Test Area']),
      idOf: (item) => item,
      nameOf: (item) => item,
      emptyMessage: 'No areas yet',
      addDialogTitle: 'New Area',
      renameDialogTitle: 'Rename Area',
      onRetry: () {},
      onTap: (_) {},
      onCreate: (_) async {},
      onRename: onRename ?? (item, name) async {},
      onDelete: onDelete,
      onMove: onMove,
    ),
  );
}
```

and add this group at the end of `main()`:

```dart
  group('CrudListScaffold surfaces a failed write instead of swallowing it', () {
    testWidgets(
      'a throwing onDelete shows a "Couldn\'t delete" SnackBar (audit L4: a '
      'guarded delete that matches 0 rows must never look like success)',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            onDelete: (_) async => throw Exception('0 rows affected (test)'),
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Test Area')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('area-delete-confirm-Test Area')),
        );
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't delete — please try again"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a throwing onRename shows a "Couldn\'t rename" SnackBar',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            onDelete: (_) async {},
            onRename: (_, _) async => throw Exception('0 rows affected (test)'),
          ),
        );

        await tester.tap(find.byKey(const Key('area-rename-Test Area')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't rename — please try again"),
          findsOneWidget,
        );
      },
    );
  });
```

In `test/features/library/presentation/topos_screen_test.dart`, add beside
`_ThrowingSetCoordinatesRepository` (after `:331`):

```dart
/// A repository whose `softDeleteWall` fails the way a row-count-verified
/// guarded delete does when ownership is unknowable (audit L4) — used to
/// prove `_TopoRow._handleDelete` SURFACES that instead of dismissing the
/// confirm sheet as if the topo were gone.
class _ThrowingSoftDeleteWallRepository extends LibraryCrudRepository {
  _ThrowingSoftDeleteWallRepository(super.db, {required super.nowMs});

  @override
  Future<void> softDeleteWall(String id) {
    throw const LibraryWriteLostException(
      operation: 'softDeleteWall',
      rowId: 'test',
      reason: LibraryWriteLostReason.ownerIdentityUnknown,
    );
  }
}
```

and this test (place it next to the existing `'coord-capture isolation'` group, which already shows the
`libraryCrudRepositoryProvider.overrideWithValue(repo)` + `syncOrchestratorProvider` override shape at
`:1822-1838`):

```dart
  group('L4: a topo delete that cannot be applied is surfaced, not silent', () {
    testWidgets(
      'a repo whose softDeleteWall throws leaves the row in the list AND '
      'shows a failure SnackBar',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = _ThrowingSoftDeleteWallRepository(db, nowMs: () => 1000);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            libraryCrudRepositoryProvider.overrideWithValue(repo),
            syncOrchestratorProvider.overrideWith(() => _FakeSyncOrchestrator()),
          ],
        );
        addTearDown(container.dispose);

        final wallId = await _dbWork(
          tester,
          () => repo.createTopo('Doomed Topo'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-delete-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-delete-confirm-$wallId')));
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't delete — please try again"),
          findsOneWidget,
        );
        expect(find.text('Doomed Topo'), findsOneWidget);
      },
    );
  });
```

Add `import 'package:masi/features/library/data/library_crud_repository.dart';` to
`topos_screen_test.dart` only if it is not already imported (it is — via the `LibraryCrudRepository`
subclass at `:320`).

- [ ] **Step 2: Run it, see it fail**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/crud_list_scaffold_test.dart test/features/library/presentation/topos_screen_test.dart
```

Expected: all 3 new tests fail with an **unhandled** exception surfacing as the test failure
(`Exception: 0 rows affected (test)` / `LibraryWriteLostException(softDeleteWall, …)`) plus
`Expected: exactly one matching candidate / Actual: Found 0 widgets with text "Couldn't delete — please try again"`
— today nothing between the repo and the button catches, so the throw escapes an unawaited handler.

- [ ] **Step 3: Minimal implementation**

**3a.** In `lib/features/library/presentation/crud_list_scaffold.dart`, add the helper next to the
handlers and route all three through it:

```dart
  /// Runs [action] and turns a failure into a user-visible [SnackBar] instead
  /// of an unhandled exception escaping a button callback.
  ///
  /// The repository's guarded mutations now VERIFY their affected row count
  /// (see `LibraryWriteLostException`) rather than reporting success on a
  /// 0-row update, so "the write did not land" reaches this widget as a
  /// throw — and the whole point of that fix is that the user hears about it.
  /// Catches [Object], not just that one type: a drift/IO failure is just as
  /// much a lost write from the user's point of view.
  Future<void> _runGuarded(
    BuildContext context,
    String failureMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e, st) {
      debugPrint('$entityKey write failed: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  Future<void> _handleCreate(BuildContext context) async {
    final name = await _showNameDialog(context, title: addDialogTitle);
    if (name == null) return;
    if (!context.mounted) return;
    await _runGuarded(
      context,
      "Couldn't save — please try again",
      () => onCreate(name),
    );
  }

  Future<void> _handleRename(BuildContext context, T item) async {
    final name = await _showNameDialog(
      context,
      title: renameDialogTitle,
      initialValue: nameOf(item),
    );
    if (name == null) return;
    if (!context.mounted) return;
    await _runGuarded(
      context,
      "Couldn't rename — please try again",
      () => onRename(item, name),
    );
  }
```

and in `_handleDelete`, replace the confirm branch (`:306-308`):

```dart
    if (confirmed == true) {
      if (!context.mounted) return;
      await _runGuarded(
        context,
        "Couldn't delete — please try again",
        () => onDelete(item),
      );
    }
```

**3b.** In `lib/features/library/presentation/topos_row.dart`, add the same helper to the row class and
route the four unguarded call sites through it:

```dart
  /// See `crud_list_scaffold.dart`'s identical helper: a guarded mutation
  /// that could not be applied now throws (row-count verification, audit
  /// L4), and the user must be told rather than shown a dismissed sheet.
  Future<void> _runGuarded(
    BuildContext context,
    String failureMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e, st) {
      debugPrint('Topo write failed: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }
```

`_handleRename`'s tail (`:301-304`):

```dart
    if (newName == null) return;
    if (!context.mounted) return;
    await _runGuarded(
      context,
      "Couldn't rename — please try again",
      () => ref
          .read(libraryCrudRepositoryProvider)
          .renameWall(topo.wallId, newName),
    );
```

`_handlePublish`'s confirm branch (`:403-405`):

```dart
    if (confirmed == true) {
      if (!context.mounted) return;
      await _runGuarded(
        context,
        "Couldn't publish — please try again",
        () => ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId),
      );
    }
```

`_handleUnpublish` (`:408-410`) gains a `context` so it can report:

```dart
  Future<void> _handleUnpublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) {
    return _runGuarded(
      context,
      "Couldn't unpublish — please try again",
      () => ref.read(libraryCrudRepositoryProvider).unpublishTopo(topo.wallId),
    );
  }
```

and its menu-switch call site (`:281`) becomes
`await _handleUnpublish(context, ref, topo);`.

`_handleDelete`'s confirm branch (`:499-501`):

```dart
    if (confirmed == true) {
      if (!context.mounted) return;
      await _runGuarded(
        context,
        "Couldn't delete — please try again",
        () =>
            ref.read(libraryCrudRepositoryProvider).softDeleteWall(topo.wallId),
      );
    }
```

- [ ] **Step 4: Run it, see it pass**

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/crud_list_scaffold_test.dart test/features/library/presentation/topos_screen_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/library/presentation/crud_list_scaffold.dart \
        lib/features/library/presentation/topos_row.dart \
        test/features/library/presentation/crud_list_scaffold_test.dart \
        test/features/library/presentation/topos_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(library): surface a write that could not be applied

Rename/delete/publish/unpublish awaited the repository with no catch, so
now that a guarded mutation throws when its row count says nothing landed,
that throw would escape a button callback. One `_runGuarded` helper in
CrudListScaffold (covering rename+delete for Areas/Sectors/Walls) and one
in topos_row (rename/publish/unpublish/delete) show the same
"Couldn't … — please try again" SnackBar the existing move/set-location
flows already use.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

**Assertions:**
1. The 3 new widget tests pass; full `flutter test` is **1586 passing, 0 failing**; `flutter analyze` 0.
2. Every pre-existing `crud_list_scaffold_test.dart` test (C-a, C-b ×2, move/retry groups) and every
   pre-existing `topos_screen_test.dart` test — in particular the A4 rename flow (`:735-773`), the
   delete flow (`:703-733`), `'#20: rename dialog keyboard dismissal'` (`:775+`) and the
   `'coord-capture isolation'` group (`:1810+`) — pass **unmodified**. `_runGuarded` only adds a catch
   on the failure path; the success path is byte-identical.
3. No screen file other than `crud_list_scaffold.dart` and `topos_row.dart` is touched:
   `git diff --name-only` for this commit lists exactly the 4 files above.
4. `grep -c '_runGuarded(' lib/features/library/presentation/crud_list_scaffold.dart` is 4
   (1 definition + 3 call sites); the same grep on `topos_row.dart` is 5 (1 + 4).
5. `grep -n 'captureWallGpsFromPhoto' lib/features/topo/presentation/topo_canvas_gps.dart` shows its
   outer `catch (_)` unchanged — the best-effort GPS path still degrades to `GpsCaptureResult.none`.
6. Message wording matches the established tone already in the codebase
   (`"Couldn't move — please try again"`, `sectors_screen.dart:92`).

---

## Cross-task assertions (independent verify gate)

Re-run, from a clean checkout of the four commits:

1. `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze` → **0 issues**.
2. `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test` →
   **1589 passing, 0 failing** (1576 baseline + 2 router + 5 repo + 2 cascade + 3 widget = 1588… the
   13th is the router's `erroringWithLiveSession` wiring test; if the count differs, reconcile against
   `git diff --stat` before accepting).
3. Spec §1c assertion — *"Web router: persisted-session + auth-stream-error does **not** redirect to the
   sign-in path; no-session **does**"* — is covered by `test/app/router_test.dart`'s two new tests plus
   the pre-existing fail-closed test at `:692`, all three in the same group.
4. Spec §1c assertion — *"An `_ownOrUnowned` mutation that matches 0 rows returns/throws a
   distinguishable failure; the pre-fix behaviour (silent success) fails the test"* — covered by the 7
   tests in `'L4: a guarded mutation that matches 0 rows never reports success'`. Distinguishable =
   `LibraryWriteLostException.reason`.
5. `grep -rn 'flutter build\|dart:io' ` over the diff → **no new `dart:io` import** anywhere in `lib/`
   (the web grep gate `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` stays empty).
6. Native behaviour is unchanged except where the shared fix is intentional: the router change is inert
   on native (`webAuthGateEnabledProvider` is `false` there, and the function returns on its first
   line), while the row-count guards are platform-agnostic and deliberately fix the native half of L4
   too.
7. No `StateProvider` introduced (Riverpod v3: `Notifier`/`NotifierProvider` only) — this fragment adds
   no provider at all, it only reads `hasKnownLocalSessionProvider`.
