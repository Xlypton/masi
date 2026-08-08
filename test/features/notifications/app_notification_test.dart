// Parsing a notification, and phrasing it.
//
// One property carries this whole file, and it is the one stated in
// `NotificationRows`' doc comment: a kind this build has never heard of must
// RENDER, not throw. `notifications.kind` is raw text on the server precisely
// so a new kind can ship without a coordinated client release — which is only
// true if an old client meeting a new kind produces a readable entry. If it
// crashed instead, every future addition would be a breaking change, and the
// forward-compatible column would be forward-compatible on paper only.
//
// The second property is that a raw uid never reaches the screen. An
// unresolvable actor is "Someone", which is a complete true sentence; a uuid
// in a sentence is an internal identifier leaking into the product.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/notifications/domain/app_notification.dart';

Map<String, dynamic> _row({
  String? id = 'n1',
  String? kind = 'comment',
  Object? createdAt = 1900000000000,
  String? actorId = 'u-kata',
  String? actorName = 'Kata',
  String? wallId = 'w1',
  String? ascentId,
  String? commentId = 'c1',
  String? preview = 'Nice line, the crux is stout',
  Object? readAt,
}) => {
  'id': id,
  'kind': kind,
  'createdAt': createdAt,
  'actorId': actorId,
  'actorName': actorName,
  'wallId': wallId,
  'ascentId': ascentId,
  'commentId': commentId,
  'preview': preview,
  'readAt': readAt,
};

void main() {
  group('a kind this build has never heard of', () {
    test(
      'renders as a generic entry rather than throwing — the server stores '
      'kind as raw text so a new one can ship without a client release, and '
      'that is only true if an OLD build meeting a NEW kind still renders',
      () {
        final n = AppNotification.fromRow(_row(kind: 'topo_republished'))!;
        expect(n.kind, NotificationKind.unknown);
        expect(n.sentence, 'Kata did something on your topo');
        expect(
          n.route,
          '/community/topo/w1',
          reason: 'still tappable — the user can go and see for themselves',
        );
      },
    );

    test('a missing or empty kind is unknown, not a crash', () {
      expect(
        AppNotification.fromRow(_row(kind: null))!.kind,
        NotificationKind.unknown,
      );
      expect(NotificationKind.fromWire(''), NotificationKind.unknown);
      expect(NotificationKind.fromWire(null), NotificationKind.unknown);
    });

    test('the four kinds this build DOES know still map', () {
      expect(NotificationKind.fromWire('comment'), NotificationKind.comment);
      expect(NotificationKind.fromWire('mention'), NotificationKind.mention);
      expect(NotificationKind.fromWire('like'), NotificationKind.like);
      expect(
        NotificationKind.fromWire('suggestion'),
        NotificationKind.suggestion,
      );
    });
  });

  group('a malformed row', () {
    test('with no id is dropped — it could not be marked read or de-duped', () {
      expect(AppNotification.fromRow(_row(id: null)), isNull);
      expect(AppNotification.fromRow(_row(id: '')), isNull);
      expect(AppNotification.fromRow(const {}), isNull);
    });

    test('with no timestamp is dropped — it has no place in a sorted list', () {
      expect(AppNotification.fromRow(_row(createdAt: null)), isNull);
      expect(AppNotification.fromRow(_row(createdAt: 'not a number')), isNull);
    });

    test(
      'is dropped for THOSE TWO FIELDS ONLY. Everything else has a sensible '
      'absence, because an inbox that silently loses entries whenever the '
      'server grows a field is the failure the raw-kind design exists to avoid',
      () {
        final n = AppNotification.fromRow({
          'id': 'n1',
          'createdAt': 1900000000000,
        })!;
        expect(n.kind, NotificationKind.unknown);
        expect(n.actorId, isNull);
        expect(n.route, isNull, reason: 'nothing to open — but it still shows');
        expect(n.sentence, isNotEmpty);
      },
    );

    test('a bigint that arrives as a num or a String is coerced, not cast', () {
      expect(AppNotification.fromRow(_row(createdAt: 1.9e12))!.createdAt, 1900000000000);
      expect(
        AppNotification.fromRow(_row(createdAt: '1900000000000'))!.createdAt,
        1900000000000,
      );
    });
  });

  group('naming the actor', () {
    test(
      'an actor with no profile anywhere reads "Someone" and NEVER the uid — '
      'a uuid in a sentence is an internal identifier leaking into the product',
      () {
        final n = AppNotification.fromRow(_row(actorName: null))!;
        expect(n.actorLabel, 'Someone');
        expect(n.sentence, 'Someone commented on your topo');
        expect(n.sentence, isNot(contains('u-kata')));
      },
    );

    test('a blank name from the server is treated as no name at all', () {
      expect(AppNotification.fromRow(_row(actorName: '   '))!.actorLabel, 'Someone');
    });

    test(
      'the LOCAL profiles mirror wins over the name the server sent, because '
      'display names are editable (#18) and the mirror is the live copy',
      () {
        final n = AppNotification.fromRow(_row(actorName: 'Kata'))!;
        expect(n.labelWith('Katalin'), 'Katalin');
        expect(n.sentenceWith('Katalin'), 'Katalin commented on your topo');
      },
    );

    test(
      'the server name is the FALLBACK, not dead weight: the mirror holds no '
      'actorName column, but a stranger who just commented is exactly the '
      'person this device has no profile for',
      () {
        final n = AppNotification.fromRow(_row(actorName: 'Kata'))!;
        expect(n.labelWith(null), 'Kata');
        expect(n.labelWith(''), 'Kata');
      },
    );
  });

  group('the sentence', () {
    String say(String kind, {String? ascentId}) =>
        AppNotification.fromRow(_row(kind: kind, ascentId: ascentId))!.sentence;

    test('says what happened, in words a person would use', () {
      expect(say('comment'), 'Kata commented on your topo');
      expect(say('mention'), 'Kata mentioned you in a comment');
      expect(say('like'), 'Kata liked your topo');
      expect(say('suggestion'), 'Kata suggested an edit to your topo');
    });

    test(
      'a topo and an ascent are NOT collapsed into "your post" — one is a '
      'place and the other is a climb somebody did',
      () {
        expect(say('like', ascentId: 'a1'), 'Kata liked your ascent');
        expect(say('comment', ascentId: 'a1'), 'Kata commented on your ascent');
      },
    );

    test(
      'a mention says nothing about WHOSE topo it was on. Being tagged is the '
      'fact; the tag can land on anybody\'s topo, including a stranger\'s',
      () {
        expect(say('mention', ascentId: 'a1'), 'Kata mentioned you in a comment');
      },
    );
  });

  group('where tapping goes', () {
    test('the ascent wins when both are set — the wall is only there so the '
        'entry can say WHICH topo, not because it is what to open', () {
      final n = AppNotification.fromRow(_row(wallId: 'w1', ascentId: 'a1'))!;
      expect(n.route, '/community/ascent/a1');
    });

    test('a wall-only entry opens the topo', () {
      expect(AppNotification.fromRow(_row())!.route, '/community/topo/w1');
    });

    test('an entry about nothing openable is not tappable', () {
      final n = AppNotification.fromRow(_row(wallId: null, ascentId: null))!;
      expect(n.route, isNull);
    });
  });

  group('the second line', () {
    test('a comment shows its excerpt — that is the whole reason to look', () {
      expect(
        AppNotification.fromRow(_row(kind: 'comment'))!.detail,
        'Nice line, the crux is stout',
      );
      expect(AppNotification.fromRow(_row(kind: 'mention'))!.detail, isNotNull);
    });

    test(
      'a like does NOT repeat the topo name under "Kata liked your topo". A '
      'second line that adds no fact is a second line that costs a scan',
      () {
        expect(
          AppNotification.fromRow(_row(kind: 'like', preview: 'Dolomitici'))!.detail,
          isNull,
        );
        expect(
          AppNotification.fromRow(_row(kind: 'suggestion'))!.detail,
          isNull,
        );
      },
    );

    test('an empty or absent preview is no second line', () {
      expect(AppNotification.fromRow(_row(preview: null))!.detail, isNull);
      expect(AppNotification.fromRow(_row(preview: '   '))!.detail, isNull);
    });
  });

  group('unread', () {
    test('unread is readAt being null, not a separate flag that can disagree', () {
      expect(AppNotification.fromRow(_row())!.isUnread, isTrue);
      expect(
        AppNotification.fromRow(_row(readAt: 1900000000001))!.isUnread,
        isFalse,
      );
    });
  });

  group('age', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1900000000000);
    String at(Duration ago) =>
        notificationAge(now.subtract(ago).millisecondsSinceEpoch, now: now);

    test('reads coarsely — an inbox is scanned, not read', () {
      expect(at(const Duration(seconds: 20)), 'just now');
      expect(at(const Duration(minutes: 4)), '4m');
      expect(at(const Duration(hours: 3)), '3h');
      expect(at(const Duration(days: 6)), '6d');
    });

    test(
      'caps at days rather than growing weeks and months — "23h" and "1d" are '
      'the same fact to somebody deciding whether to tap',
      () {
        expect(at(const Duration(days: 400)), '400d');
      },
    );
  });
}
