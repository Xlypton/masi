// Coverage for the profile-picture feature: the data-URL encoder + size
// guard (`avatar_picker.dart`), the render/fallback chain (`MasiAvatar`),
// the provider precedence (`myAvatarUrlProvider`), and the repository write
// (`ProfileRepository.setMyAvatarUrl`).
//
// Deliberately NO real image decode anywhere here — per CLAUDE.md, driving a
// codec under fake-async hangs. Every test either hands in bytes directly or
// overrides `avatarPickerProvider`.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/application/profile_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/account/data/avatar_picker.dart';
import 'package:masi/features/account/data/profile_repository.dart';
import 'package:masi/shared/presentation/masi_avatar.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// A 1x1 transparent PNG. Small enough to embed, and never actually decoded
/// by any test here (nothing pumps a frame that paints it to a real canvas
/// beyond the widget tree assertions below).
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// Awaits the next resolved value of an [AsyncValue] provider through a real
/// listener.
///
/// Deliberately NOT `container.read(provider.future)`: with no live listener
/// a `StreamProvider` here never leaves `AsyncLoading`, and the test times
/// out 30s later with "disposed during loading state". Holding a
/// subscription is also closer to how the widget tree actually consumes
/// these.
Future<T> _awaitValue<T>(
  ProviderContainer container,
  StreamProvider<T> provider,
) async {
  final completer = Completer<T>();
  final sub = container.listen<AsyncValue<T>>(provider, (_, next) {
    if (next case AsyncData(:final value) when !completer.isCompleted) {
      completer.complete(value);
    }
  }, fireImmediately: true);
  try {
    return await completer.future;
  } finally {
    sub.close();
  }
}

Widget _wrap(Widget child) => MaterialApp(
  theme: MasiTheme.light,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('encodeAvatarDataUrl', () {
    test('produces a base64 data URL MasiAvatar can decode back', () {
      final bytes = Uint8List.fromList(base64Decode(_tinyPngBase64));

      final url = encodeAvatarDataUrl(bytes);

      expect(url, startsWith('data:image/jpeg;base64,'));
      expect(MasiAvatar.decodeDataUrl(url), bytes);
    });

    test('refuses empty bytes rather than storing a zero-length picture', () {
      expect(
        () => encodeAvatarDataUrl(Uint8List(0)),
        throwsA(isA<AvatarPickException>()),
      );
    });

    test(
      'refuses anything over kAvatarMaxBytes — a synced row must never carry '
      'a multi-megabyte blob',
      () {
        final tooBig = Uint8List(kAvatarMaxBytes + 1);

        expect(
          () => encodeAvatarDataUrl(tooBig),
          throwsA(
            isA<AvatarPickException>().having(
              (e) => e.message,
              'message',
              contains('too large'),
            ),
          ),
        );
        // The boundary itself is allowed — the guard is >, not >=.
        expect(
          () => encodeAvatarDataUrl(Uint8List(kAvatarMaxBytes)),
          returnsNormally,
        );
      },
    );
  });

  group('MasiAvatar.decodeDataUrl', () {
    test('returns null for every shape that is not a base64 data URL', () {
      expect(MasiAvatar.decodeDataUrl('https://example.com/a.png'), isNull);
      // A data URL with no comma at all.
      expect(MasiAvatar.decodeDataUrl('data:image/jpeg;base64'), isNull);
      // A data URL that is not base64-encoded (percent-encoded payload).
      expect(MasiAvatar.decodeDataUrl('data:image/svg+xml,%3Csvg/%3E'), isNull);
      // Well-formed prefix, payload that will not decode.
      expect(MasiAvatar.decodeDataUrl('data:image/jpeg;base64,!!!!'), isNull);
    });
  });

  group('MasiAvatar rendering', () {
    testWidgets('falls back to email initials when there is no picture', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MasiAvatar(
            avatarUrl: null,
            email: 'peter.keri@example.com',
            radius: 24,
          ),
        ),
      );

      expect(find.text('PK'), findsOneWidget);
    });

    testWidgets(
      'falls back to the person glyph when the email yields no initials',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const MasiAvatar(avatarUrl: null, email: null, radius: 24)),
        );

        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'person'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'keeps the initials painted UNDERNEATH a picture (foregroundImage, not '
      'backgroundImage) so a failed load reveals them instead of a blank disc',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            MasiAvatar(
              avatarUrl: 'data:image/png;base64,$_tinyPngBase64',
              email: 'peter.keri@example.com',
              radius: 24,
            ),
          ),
        );

        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatar.foregroundImage, isA<MemoryImage>());
        expect(avatar.backgroundImage, isNull);
        expect(find.text('PK'), findsOneWidget);
      },
    );

    testWidgets('uses a NetworkImage for an https provider avatar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MasiAvatar(
            avatarUrl: 'https://lh3.googleusercontent.com/a/x=s96-c',
            email: 'a@b.com',
            radius: 14,
          ),
        ),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.foregroundImage, isA<NetworkImage>());
    });

    testWidgets(
      'a URL that is neither a data: nor an http(s): URL is ignored rather '
      'than handed to an image loader that would throw',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const MasiAvatar(
              avatarUrl: '/var/mobile/some/path.jpg',
              email: 'a@b.com',
              radius: 14,
            ),
          ),
        );

        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatar.foregroundImage, isNull);
      },
    );
  });

  group('myAvatarUrlProvider precedence', () {
    late AppDatabase db;
    late ProviderContainer container;

    const uid = 'uid-1';
    const googleAvatar = 'https://lh3.googleusercontent.com/a/google=s96-c';

    ProviderContainer build({String? providerAvatarUrl}) {
      db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          authStateProvider.overrideWith(
            (ref) => Stream.value(
              AuthSessionState.signedIn(
                'a@b.com',
                uid: uid,
                providerAvatarUrl: providerAvatarUrl,
              ),
            ),
          ),
          // §1c: `effectiveUidProvider` normally reaches through
          // `authRepositoryProvider.currentSession`, so overriding the auth
          // STREAM alone would leave it null and every local read unscoped.
          effectiveUidProvider.overrideWithValue(uid),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('falls back to the provider avatar when the profile has none', () async {
      container = build(providerAvatarUrl: googleAvatar);

      expect(await _awaitValue(container, myAvatarUrlProvider), googleAvatar);
    });

    test('a picture set in this app WINS over the provider avatar', () async {
      container = build(providerAvatarUrl: googleAvatar);
      const own = 'data:image/jpeg;base64,$_tinyPngBase64';
      await container.read(profileRepositoryProvider).setMyAvatarUrl(own);

      expect(await _awaitValue(container, myAvatarUrlProvider), own);
    });

    test(
      'clearing the app picture falls BACK to the provider avatar rather than '
      'to nothing — that is what "Use my Google photo" relies on',
      () async {
        container = build(providerAvatarUrl: googleAvatar);
        final repo = container.read(profileRepositoryProvider);

        await repo.setMyAvatarUrl('data:image/jpeg;base64,$_tinyPngBase64');
        await repo.setMyAvatarUrl(null);

        expect(await _awaitValue(container, myAvatarUrlProvider), googleAvatar);
      },
    );

    test('resolves to null when there is neither', () async {
      container = build();

      expect(await _awaitValue(container, myAvatarUrlProvider), isNull);
    });
  });

  group('ProfileRepository.setMyAvatarUrl', () {
    test(
      'marks the row dirty and preserves createdAt on update, and leaves '
      'displayName alone',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        var now = 1000;
        final repo = ProfileRepository(
          db,
          nowMs: () => now,
          currentUid: () => 'uid-1',
        );

        await repo.setMyDisplayName('Peter');
        now = 2000;
        await repo.setMyAvatarUrl('data:image/jpeg;base64,$_tinyPngBase64');

        final row = await db.select(db.profiles).getSingle();
        expect(row.createdAt, 1000, reason: 'createdAt must never be rewritten');
        expect(row.updatedAt, 2000);
        expect(row.dirty, isTrue);
        expect(row.displayName, 'Peter');
        expect(row.avatarUrl, startsWith('data:image/jpeg;base64,'));

        now = 3000;
        await repo.setMyAvatarUrl(null);
        final cleared = await db.select(db.profiles).getSingle();
        expect(cleared.avatarUrl, isNull);
        expect(cleared.displayName, 'Peter', reason: 'clearing one facet must not blank the other');
      },
    );

    test('is a silent no-op when signed out — there is no uid to key a row by', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = ProfileRepository(
        db,
        nowMs: () => 1000,
        currentUid: () => null,
      );

      await repo.setMyAvatarUrl('data:image/jpeg;base64,$_tinyPngBase64');

      expect(await db.select(db.profiles).get(), isEmpty);
    });
  });
}
