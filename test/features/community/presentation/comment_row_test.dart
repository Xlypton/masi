// Coverage for `CommentRow` — the one comment row both the topo thread and
// the ascent thread now render.
//
// The behaviour under test is the identity line: WHICH name wins, and what
// happens when each source is missing. That matters because the name used to
// come from `Comment.authorName`, a text snapshot stamped from the author's
// email local-part at write time and then frozen forever.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/data/comments_repository.dart';
import 'package:masi/features/community/presentation/comment_row.dart';
import 'package:masi/shared/presentation/masi_avatar.dart';

void main() {
  late db.AppDatabase database;
  late ProviderContainer container;

  setUp(() {
    database = db.AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  /// Writes a profile row for [uid] — the thing every OTHER user resolves an
  /// author through.
  Future<void> seedProfile(
    String uid, {
    String? displayName,
    String? avatarUrl,
  }) async {
    await database
        .into(database.profiles)
        .insert(
          db.ProfilesCompanion.insert(
            id: uid,
            createdAt: 1000,
            updatedAt: 1000,
            ownerId: Value(uid),
            displayName: Value(displayName),
            avatarUrl: Value(avatarUrl),
          ),
        );
  }

  Comment comment({String? ownerId, String? authorName}) => Comment(
    id: 'c1',
    wallId: 'w1',
    body: 'Great line!',
    authorName: authorName,
    ownerId: ownerId,
    createdAt: 1000,
    updatedAt: 1000,
  );

  Future<void> pumpRow(WidgetTester tester, Comment value) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: CommentRow(comment: value, keyPrefix: 'community-comment'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the LIVE profile display name wins over the name stamped on the comment '
    '— the stamped one is frozen at write time, so a climber who has since '
    'set a real name kept showing up in old threads as their email local-part',
    (tester) async {
      await seedProfile('uid-1', displayName: 'Bogi Devecser');
      await pumpRow(
        tester,
        comment(ownerId: 'uid-1', authorName: 'bogi.devecser'),
      );

      expect(find.text('Bogi Devecser'), findsOneWidget);
      expect(find.text('bogi.devecser'), findsNothing);
    },
  );

  testWidgets(
    'falls back to the stamped authorName when the author has no profile row '
    'pulled yet — a comment must still say who wrote it while the profile '
    'fetch is outstanding',
    (tester) async {
      await pumpRow(tester, comment(ownerId: 'uid-1', authorName: 'climber'));

      expect(find.text('climber'), findsOneWidget);
    },
  );

  testWidgets(
    'a profile row whose displayName is blank falls through rather than '
    'rendering an empty identity line',
    (tester) async {
      await seedProfile('uid-1', displayName: '   ');
      await pumpRow(tester, comment(ownerId: 'uid-1', authorName: 'climber'));

      expect(find.text('climber'), findsOneWidget);
    },
  );

  testWidgets('with neither source, the author reads Anonymous', (
    tester,
  ) async {
    await pumpRow(tester, comment());

    expect(find.text('Anonymous'), findsOneWidget);
  });

  testWidgets(
    'the raw uid is NEVER rendered — the one thing an identity line must not '
    'leak, and the same rule the feed rows follow',
    (tester) async {
      await pumpRow(tester, comment(ownerId: 'uid-1'));

      expect(find.textContaining('uid-1'), findsNothing);
    },
  );

  testWidgets('the author\'s profile picture is drawn beside their name', (
    tester,
  ) async {
    await seedProfile(
      'uid-1',
      displayName: 'Bogi Devecser',
      avatarUrl: 'https://example.test/a.jpg',
    );
    await pumpRow(tester, comment(ownerId: 'uid-1'));

    final avatar = tester.widget<MasiAvatar>(find.byType(MasiAvatar));
    expect(avatar.avatarUrl, 'https://example.test/a.jpg');
    // Initials come from the display name, and the row never learns the
    // author's email — a thread has no business knowing addresses.
    expect(avatar.displayName, 'Bogi Devecser');
    expect(avatar.email, isNull);
  });

  testWidgets(
    'a signed-out author (no ownerId) still renders — there is no uid to key '
    'a profile row by, so both lookups are skipped rather than asked for a '
    'name they cannot have',
    (tester) async {
      await pumpRow(tester, comment(authorName: 'guest'));

      expect(find.text('guest'), findsOneWidget);
      expect(tester.widget<MasiAvatar>(find.byType(MasiAvatar)).avatarUrl, isNull);
    },
  );

  testWidgets('the key is prefixed by the caller, so both threads keep theirs', (
    tester,
  ) async {
    await pumpRow(tester, comment(ownerId: 'uid-1', authorName: 'climber'));

    expect(find.byKey(const Key('community-comment-c1')), findsOneWidget);
    expect(find.byKey(const Key('community-comment-c1-avatar')), findsOneWidget);
  });
}
