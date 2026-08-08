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

  Comment comment({
    String? ownerId,
    String? authorName,
    String body = 'Great line!',
    List<String> mentionedUids = const [],
  }) => Comment(
    id: 'c1',
    wallId: 'w1',
    body: body,
    authorName: authorName,
    ownerId: ownerId,
    createdAt: 1000,
    updatedAt: 1000,
    mentionedUids: mentionedUids,
  );

  /// The pieces of the body as actually painted, mention spans included — a
  /// body with mentions renders as a `Text.rich`, which `find.text` cannot see.
  List<InlineSpan> bodySpans(WidgetTester tester) {
    final rich = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((t) => t.textSpan != null);
    return (rich.textSpan! as TextSpan).children!;
  }

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

  // Tagging other climbers. Same argument as the identity line above, one
  // level down: the `@Bogi` in the body is text frozen at write time, and the
  // uid is the reference.
  group('mentions', () {
    testWidgets(
      'a comment that tags nobody still renders as a plain Text — a Text.rich '
      'has no `data`, so switching every comment to one would silently blind '
      'find.text and every test that looks for a comment by its words',
      (tester) async {
        await pumpRow(tester, comment(body: 'Great line!'));

        expect(find.text('Great line!'), findsOneWidget);
      },
    );

    testWidgets(
      'a mention is drawn in the accent colour, so a tag reads as a reference '
      'to a person rather than as the words around it',
      (tester) async {
        await seedProfile('uid-2', displayName: 'Bogi');
        await pumpRow(
          tester,
          comment(
            ownerId: 'uid-1',
            body: 'Nice one @Bogi',
            mentionedUids: const ['uid-2'],
          ),
        );

        final spans = bodySpans(tester).cast<TextSpan>();
        final mention = spans.firstWhere((s) => s.text == '@Bogi');
        expect(mention.style?.color, MasiColors.light.accent);
        // The surrounding words are NOT accented — otherwise "visually
        // distinct" means nothing.
        expect(spans.firstWhere((s) => s.text == 'Nice one ').style, isNull);
      },
    );

    testWidgets(
      'the LIVE display name is drawn, not the one frozen in the body — a '
      'climber who has renamed themselves is the entire reason mentions are '
      'stored as uids',
      (tester) async {
        await seedProfile('uid-2', displayName: 'Bogi Nagy');
        await pumpRow(
          tester,
          comment(
            ownerId: 'uid-1',
            body: 'Nice one @Bogi',
            mentionedUids: const ['uid-2'],
          ),
        );

        final texts = bodySpans(tester).cast<TextSpan>().map((s) => s.text);
        expect(texts, contains('@Bogi Nagy'));
      },
    );

    testWidgets(
      'a tagged climber whose profile row has not been pulled yet keeps the '
      'literal text that was typed, and NEVER shows the raw uid',
      (tester) async {
        await pumpRow(
          tester,
          comment(
            ownerId: 'uid-1',
            body: 'Nice one @Bogi',
            mentionedUids: const ['uid-2'],
          ),
        );

        final texts = bodySpans(tester).cast<TextSpan>().map((s) => s.text);
        expect(texts, contains('@Bogi'));
        expect(texts.join(), isNot(contains('uid-2')));
      },
    );
  });
}
