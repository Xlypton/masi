import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart' as db;

/// CRUD + reads over the `Profiles` table (#18: editable, synced display
/// name).
///
/// A profile row's [db.Profile.id] IS the Supabase Auth uid — see
/// `tables.dart`'s `Profiles` doc — so "my profile" is always
/// `profiles.id == currentUid()`, the same lookup [watchDisplayName] uses to
/// resolve ANY other user's display name (e.g. the author of a pulled
/// shared topo). There is no notion of a signed-out-owned profile row: with
/// no uid there's nothing to key a row by, so every write here is a no-op
/// (never throws) when [currentUid] returns `null` — mirroring
/// `AscentsRepository`'s "signed-out degrades to a safe no-op", not its
/// "signed-out rows keyed by `ownerId IS NULL`" behavior, since that has no
/// meaning for a table whose very primary key IS the uid.
class ProfileRepository {
  ProfileRepository(this._db, {required this.nowMs, this.currentUid = _noUid});

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at each write. Defaults to always-`null` so callers that
  /// don't pass this get signed-out (no-op) behavior.
  final String? Function() currentUid;

  static String? _noUid() => null;

  /// Upserts the signed-in user's own profile row with [name]: `updatedAt`
  /// is bumped to `nowMs()` and the row is marked `dirty` so a future sync
  /// push picks it up. A brand-new row is inserted with `createdAt ==
  /// updatedAt == nowMs()` and `ownerId` stamped to the same uid as [id]
  /// (see the class doc); an existing row keeps its original `createdAt`
  /// untouched (only `displayName`/`updatedAt`/`dirty` change) — mirroring
  /// every other repository's "never rewrite createdAt on update"
  /// convention.
  ///
  /// No-op (never throws) when signed out — there is no uid to key a
  /// profile row by.
  Future<void> setMyDisplayName(String name) async {
    final uid = currentUid();
    if (uid == null) return;

    final now = nowMs();
    final existing = await (_db.select(
      _db.profiles,
    )..where((t) => t.id.equals(uid))).getSingleOrNull();

    if (existing == null) {
      await _db
          .into(_db.profiles)
          .insert(
            db.ProfilesCompanion.insert(
              id: uid,
              createdAt: now,
              updatedAt: now,
              dirty: const Value(true),
              ownerId: Value(uid),
              displayName: Value(name),
            ),
          );
    } else {
      await (_db.update(
        _db.profiles,
      )..where((t) => t.id.equals(uid))).write(
        db.ProfilesCompanion(
          updatedAt: Value(now),
          dirty: const Value(true),
          displayName: Value(name),
        ),
      );
    }
  }

  /// Upserts the signed-in user's own profile picture — see
  /// [db.Profiles.avatarUrl] for the two accepted shapes. Passing `null`
  /// CLEARS it, which is how "Remove photo" works; the UI then falls back to
  /// the OAuth provider's avatar and finally to the initials chip.
  ///
  /// Same upsert/dirty/`createdAt`-preserving semantics as
  /// [setMyDisplayName], and the same signed-out no-op — deliberately a
  /// separate method rather than optional parameters on that one, so setting
  /// a picture can never blank a display name (or vice versa) by omission.
  Future<void> setMyAvatarUrl(String? avatarUrl) async {
    final uid = currentUid();
    if (uid == null) return;

    final now = nowMs();
    final existing = await (_db.select(
      _db.profiles,
    )..where((t) => t.id.equals(uid))).getSingleOrNull();

    if (existing == null) {
      await _db
          .into(_db.profiles)
          .insert(
            db.ProfilesCompanion.insert(
              id: uid,
              createdAt: now,
              updatedAt: now,
              dirty: const Value(true),
              ownerId: Value(uid),
              avatarUrl: Value(avatarUrl),
            ),
          );
    } else {
      await (_db.update(
        _db.profiles,
      )..where((t) => t.id.equals(uid))).write(
        db.ProfilesCompanion(
          updatedAt: Value(now),
          dirty: const Value(true),
          // `Value(null)` (not `Value.absent()`) — clearing is a real write
          // here, not "leave it alone".
          avatarUrl: Value(avatarUrl),
        ),
      );
    }
  }

  /// Copies the identity provider's picture (today: Google) into the
  /// signed-in user's own `avatarUrl`, so that **other people can see it**.
  ///
  /// Why this is needed at all: the provider avatar lives on the auth session
  /// ([AuthSessionState.providerAvatarUrl]) and a session is readable only by
  /// the user it belongs to. Everyone else resolves an author through the
  /// `profiles` row, so before this ran, a user who had never opened Account
  /// and picked a photo appeared to the whole community as their initials —
  /// which made "comments show the profile picture" look unimplemented for
  /// almost every real account.
  ///
  /// **It never overwrites a picture the user chose in-app.** Those are always
  /// `data:` URLs (see `avatar_picker.dart`, which base64-encodes the bytes),
  /// so a stored `data:` value is an explicit choice and is left alone. A
  /// stored `http(s)` value can only have come from a previous adoption, so it
  /// is refreshed when the provider hands out a different URL — Google's
  /// `lh3.googleusercontent.com` links do rotate, and a stale one 404s (which
  /// [MasiAvatar] renders as the initials, not a broken glyph).
  ///
  /// No-op, never throws, when signed out or when the session carries no
  /// picture — a missing avatar is not an error anywhere in this app.
  ///
  /// Note this is the one write here that does NOT take the user through a
  /// choice: it publishes the picture their identity provider already holds.
  /// It matches what the app has always shown the user as their own avatar
  /// (`myAvatarUrlProvider` falls back to the provider picture), so nothing
  /// they see changes — what changes is that everyone else now sees it too.
  Future<void> adoptProviderAvatarUrl(String? providerAvatarUrl) async {
    final uid = currentUid();
    if (uid == null) return;
    final incoming = providerAvatarUrl?.trim();
    if (incoming == null || incoming.isEmpty) return;
    if (!incoming.startsWith('http://') && !incoming.startsWith('https://')) {
      return;
    }

    final existing = await (_db.select(
      _db.profiles,
    )..where((t) => t.id.equals(uid))).getSingleOrNull();

    final current = existing?.avatarUrl;
    if (current != null && current.startsWith('data:')) return;
    if (current == incoming) return;

    await setMyAvatarUrl(incoming);
  }

  /// Reactive display name for the profile row keyed by [uid] (any user, not
  /// just the signed-in one — this is how a shared topo's author name is
  /// resolved). Emits `null` when no row exists yet, the row has no
  /// `displayName` set, or the row is soft-deleted.
  Stream<String?> watchDisplayName(String uid) {
    final query = _db.select(_db.profiles)
      ..where((t) => t.id.equals(uid) & t.deletedAt.isNull());
    return query.watchSingleOrNull().map((row) => row?.displayName);
  }

  /// Reactive profile picture for the profile row keyed by [uid] (any user,
  /// same as [watchDisplayName]). Emits `null` when no row exists, the row
  /// has no picture set, or the row is soft-deleted — every one of which
  /// means "fall back", never "error".
  Stream<String?> watchAvatarUrl(String uid) {
    final query = _db.select(_db.profiles)
      ..where((t) => t.id.equals(uid) & t.deletedAt.isNull());
    return query.watchSingleOrNull().map((row) => row?.avatarUrl);
  }
}
