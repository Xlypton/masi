// Coverage for the comment composer's @-mention picker: when it opens, who it
// offers, and what picking somebody actually does to the draft.
//
// The behaviour that matters here is the seam between the text and the tags.
// The body carries an `@name` that will go stale, and the column carries the
// uid that will not — so a pick has to do BOTH, and a mention the user then
// deletes has to stop counting as one.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/community/presentation/mention_composer.dart';

void main() {
  late db.AppDatabase database;
  late MentionComposerController controller;

  setUp(() {
    database = db.AppDatabase(NativeDatabase.memory());
    controller = MentionComposerController();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  Future<void> seedProfile(String uid, String displayName) async {
    await database
        .into(database.profiles)
        .insert(
          db.ProfilesCompanion.insert(
            id: uid,
            createdAt: 1000,
            updatedAt: 1000,
            ownerId: Value(uid),
            displayName: Value(displayName),
          ),
        );
  }

  /// The composer as the two threads assemble it: the picker directly above the
  /// field it belongs to.
  Future<void> pumpComposer(
    WidgetTester tester, {
    Set<String> participantUids = const {},
    String? selfUid,
  }) async {
    // `UncontrolledProviderScope` over a container this test owns, NOT a plain
    // `ProviderScope`, and the difference is load-bearing.
    //
    // A `ProviderScope` disposes its container while the WIDGET TREE is being
    // torn down, inside `BuildOwner.finalizeTree`. Riverpod then cancels the
    // Drift query streams under `profileDisplayNameProvider`, and drift's
    // `StreamQueryStore.markAsClosed` schedules a zero-duration `Timer` to do
    // the close. The tree is gone by then, nothing pumps again, and
    // flutter_test asserts "A Timer is still pending even after the widget tree
    // was disposed" — which poisons the binding, so every test after it in the
    // file reports "did not complete" and this file's coverage silently
    // collapses to whatever ran first.
    //
    // Owning the container moves the disposal into `addTearDown`, where the
    // binding is still live enough to service the timer.
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        nowMsProvider.overrideWithValue(() => 1000),
        // The real one reads a Supabase session, which no widget test has.
        effectiveUidProvider.overrideWithValue(selfUid),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: Column(
              children: [
                MentionSuggestions(
                  controller: controller,
                  keyPrefix: 'community-comment',
                  participantUids: participantUids,
                ),
                TextField(
                  key: const Key('community-comment-field'),
                  controller: controller,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder suggestion(String uid) =>
      find.byKey(Key('community-comment-mention-suggestion-$uid'));

  testWidgets(
    'the picker stays out of the way until an @ is typed — a list hanging over '
    'the keyboard for an ordinary comment is noise',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      expect(
        find.byKey(const Key('community-comment-mention-suggestions')),
        findsNothing,
      );

      await tester.enterText(find.byType(TextField), 'Nice lead');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-comment-mention-suggestions')),
        findsNothing,
      );
    },
  );

  testWidgets('typing @ opens the picker with climbers to tag', (tester) async {
    await seedProfile('uid-bogi', 'Bogi Devecser');
    await pumpComposer(tester);

    await tester.enterText(find.byType(TextField), 'Nice one @');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('community-comment-mention-suggestions')),
      findsOneWidget,
    );
    expect(suggestion('uid-bogi'), findsOneWidget);
  });

  testWidgets('the list narrows as the name is typed out', (tester) async {
    await seedProfile('uid-bogi', 'Bogi Devecser');
    await seedProfile('uid-zsofi', 'Zsofi Kiss');
    await pumpComposer(tester);

    await tester.enterText(find.byType(TextField), 'Nice one @zso');
    await tester.pumpAndSettle();

    expect(suggestion('uid-zsofi'), findsOneWidget);
    expect(suggestion('uid-bogi'), findsNothing);
  });

  testWidgets(
    'people already in this thread are offered before anyone else — that is '
    'who a tag is overwhelmingly aimed at',
    (tester) async {
      await seedProfile('uid-bogi', 'Aaron Bogi');
      await seedProfile('uid-zsofi', 'Zsofi Kiss');
      await pumpComposer(tester, participantUids: const {'uid-zsofi'});

      await tester.enterText(find.byType(TextField), '@');
      await tester.pumpAndSettle();

      final zsofi = tester.getTopLeft(suggestion('uid-zsofi')).dy;
      final bogi = tester.getTopLeft(suggestion('uid-bogi')).dy;
      expect(zsofi, lessThan(bogi));
    },
  );

  testWidgets('the signed-in user is never offered their own name', (
    tester,
  ) async {
    await seedProfile('uid-me', 'Me Myself');
    await seedProfile('uid-bogi', 'Bogi Devecser');
    await pumpComposer(tester, selfUid: 'uid-me');

    await tester.enterText(find.byType(TextField), '@');
    await tester.pumpAndSettle();

    expect(suggestion('uid-me'), findsNothing);
    expect(suggestion('uid-bogi'), findsOneWidget);
  });

  testWidgets(
    'picking somebody writes their name into the draft AND records their uid '
    '— the text is what the reader sees, the uid is what survives a rename',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), 'Nice one @bo');
      await tester.pumpAndSettle();
      await tester.tap(suggestion('uid-bogi'));
      await tester.pumpAndSettle();

      expect(controller.text, 'Nice one @Bogi Devecser ');
      expect(controller.mentionedUids, ['uid-bogi']);
    },
  );

  testWidgets(
    'the picker closes after a pick — without the trailing space the caret is '
    'still inside the name it just completed, and the list reopens over it',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), '@bo');
      await tester.pumpAndSettle();
      await tester.tap(suggestion('uid-bogi'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-comment-mention-suggestions')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a mention the user then deletes stops being one — a uid left behind would '
    'tag somebody in a comment that never names them',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), '@bo');
      await tester.pumpAndSettle();
      await tester.tap(suggestion('uid-bogi'));
      await tester.pumpAndSettle();
      expect(controller.mentionedUids, ['uid-bogi']);

      await tester.enterText(find.byType(TextField), 'Nice lead');
      await tester.pumpAndSettle();

      expect(controller.mentionedUids, isEmpty);
    },
  );

  testWidgets(
    'posting clears the tags along with the text, so the next comment does not '
    'inherit the last one\'s mentions',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), '@bo');
      await tester.pumpAndSettle();
      await tester.tap(suggestion('uid-bogi'));
      await tester.pumpAndSettle();

      controller.clear();

      expect(controller.mentions, isEmpty);
      expect(controller.mentionedUids, isEmpty);
    },
  );

  testWidgets(
    'an email address in the draft does not summon the picker — the @ has to '
    'start a word',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), 'mail bogi@example.test');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-comment-mention-suggestions')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a query nobody matches collapses the picker rather than showing an empty '
    'box — "no such climber" is not news to somebody mid-name',
    (tester) async {
      await seedProfile('uid-bogi', 'Bogi Devecser');
      await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), '@qqq');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-comment-mention-suggestions')),
        findsNothing,
      );
    },
  );
}
