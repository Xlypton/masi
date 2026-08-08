// Coverage for the pure half of @-mentions: the codec for the
// `Comments.mentionedUids` column, the composer's `@…` query detection, the
// candidate ranking, and the parse that turns a stored body plus a uid list
// back into styled spans.
//
// This is where every sharp edge in the feature lives. The column is text that
// a server, an older client or a bad sync could have written; the body is
// whatever somebody typed on a phone; and the display name a mention was
// written against is editable, so it is expected to be wrong by the time
// anybody reads it.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/domain/comment_mentions.dart';

void main() {
  group('encodeMentionedUids', () {
    test(
      'a comment that tags nobody stores null, not "[]" — almost every comment '
      'is one, and an empty array costs a byte on every row and every push to '
      'say what an absent value already says',
      () {
        expect(encodeMentionedUids(const []), isNull);
        expect(encodeMentionedUids(const ['', '   ']), isNull);
      },
    );

    test('tagged uids store as a JSON array of strings', () {
      expect(encodeMentionedUids(['uid-a', 'uid-b']), '["uid-a","uid-b"]');
    });

    test(
      'blanks, whitespace padding and duplicates are tidied on the way in, so '
      'the column never has to be trusted to be tidy on the way out',
      () {
        expect(
          encodeMentionedUids([' uid-a ', 'uid-a', '', 'uid-b']),
          '["uid-a","uid-b"]',
        );
      },
    );
  });

  group('decodeMentionedUids', () {
    test('an absent or empty column means the comment tags nobody', () {
      expect(decodeMentionedUids(null), isEmpty);
      expect(decodeMentionedUids(''), isEmpty);
      expect(decodeMentionedUids('   '), isEmpty);
      expect(decodeMentionedUids('[]'), isEmpty);
    });

    test('a well-formed array decodes in order', () {
      expect(decodeMentionedUids('["uid-a","uid-b"]'), ['uid-a', 'uid-b']);
    });

    test(
      'malformed JSON degrades to "tags nobody" rather than throwing — this '
      'runs on the render path of every comment in a thread, and a thread that '
      'throws while painting is far worse than a mention that does not render',
      () {
        expect(decodeMentionedUids('not json at all'), isEmpty);
        expect(decodeMentionedUids('["uid-a"'), isEmpty);
      },
    );

    test(
      'a JSON object where an array was expected decodes to nothing — '
      'salvaging something from it would be guessing at a writer this app does '
      'not have',
      () {
        expect(decodeMentionedUids('{"uids":["uid-a"]}'), isEmpty);
        expect(decodeMentionedUids('"uid-a"'), isEmpty);
        expect(decodeMentionedUids('42'), isEmpty);
      },
    );

    test(
      'non-string elements are skipped and the usable ones survive — a number '
      'as a uid would key a profile lookup that can never match',
      () {
        expect(decodeMentionedUids('["uid-a",42,null,true,"uid-b"]'), [
          'uid-a',
          'uid-b',
        ]);
      },
    );

    test('duplicates and blanks collapse', () {
      expect(decodeMentionedUids('["uid-a","","uid-a"," uid-b "]'), [
        'uid-a',
        'uid-b',
      ]);
    });

    test('what encode writes, decode reads back unchanged', () {
      final encoded = encodeMentionedUids(['uid-a', 'uid-b']);
      expect(decodeMentionedUids(encoded), ['uid-a', 'uid-b']);
    });
  });

  group('activeMentionQuery', () {
    test('typing @ opens a query, and the following characters narrow it', () {
      expect(activeMentionQuery('@', 1), (start: 0, query: ''));
      expect(activeMentionQuery('Nice one @bo', 12), (start: 9, query: 'bo'));
    });

    test(
      'an email address does not open the picker — the @ has to start a word, '
      'or a composer pops a name list over every address anyone types',
      () {
        expect(activeMentionQuery('write to bogi@example.test', 25), isNull);
      },
    );

    test(
      'one space is allowed (display names here are commonly First Last) but a '
      'second ends the query — everything after the last @ in a paragraph is '
      'not a name and will never resolve to one',
      () {
        expect(activeMentionQuery('@Bogi Dev', 9), (start: 0, query: 'Bogi Dev'));
        expect(activeMentionQuery('@Bogi Dev sent', 14), isNull);
      },
    );

    test('a newline between the @ and the caret ends the query', () {
      expect(activeMentionQuery('@Bogi\nnice', 10), isNull);
    });

    test(
      'a very long run after an @ is not a name — the bound stops a stray @ '
      'early in a comment from keeping the picker armed for the rest of it',
      () {
        final long = '@${'a' * (kMaxMentionQueryLength + 5)}';
        expect(activeMentionQuery(long, long.length), isNull);
      },
    );

    test('a caret before the @, or in text with none, has no query', () {
      expect(activeMentionQuery('hi @bo', 2), isNull);
      expect(activeMentionQuery('no tags here', 12), isNull);
      expect(activeMentionQuery('', 0), isNull);
    });
  });

  group('mentionedUidsInBody', () {
    const bogi = PendingMention(uid: 'uid-bogi', insertedName: 'Bogi');
    const zsofi = PendingMention(uid: 'uid-zsofi', insertedName: 'Zsofi');

    test(
      'a mention the user typed over is NOT stored — a uid left behind would '
      'notify somebody for a tag nobody can see in the comment',
      () {
        expect(
          mentionedUidsInBody('Nice lead!', const [bogi, zsofi]),
          isEmpty,
        );
        expect(
          mentionedUidsInBody('Nice lead @Zsofi', const [bogi, zsofi]),
          ['uid-zsofi'],
        );
      },
    );

    test(
      'the stored order is BODY order, not pick order — the render side falls '
      'back to matching mentions positionally, which only works if it is',
      () {
        expect(
          mentionedUidsInBody('@Zsofi and @Bogi were there', const [
            bogi,
            zsofi,
          ]),
          ['uid-zsofi', 'uid-bogi'],
        );
      },
    );

    test('the same person picked twice is stored once', () {
      expect(
        mentionedUidsInBody('@Bogi @Bogi', const [
          bogi,
          PendingMention(uid: 'uid-bogi', insertedName: 'Bogi'),
        ]),
        ['uid-bogi'],
      );
    });
  });

  group('rankMentionCandidates', () {
    const pool = [
      MentionCandidate(uid: 'uid-1', displayName: 'Bogi Devecser'),
      MentionCandidate(uid: 'uid-2', displayName: 'Zsofi Kiss'),
      MentionCandidate(uid: 'uid-3', displayName: 'Bence Nagy'),
      MentionCandidate(uid: 'uid-nameless', displayName: '   '),
    ];

    test(
      'somebody already in this thread is offered first — that is who a tag is '
      'overwhelmingly aimed at',
      () {
        final ranked = rankMentionCandidates(
          pool: pool,
          query: '',
          participantUids: const {'uid-2'},
        );
        expect(ranked.first.uid, 'uid-2');
      },
    );

    test(
      'people outside the thread are still offered, so tagging the friend you '
      'climbed with who has not commented yet is possible at all',
      () {
        final ranked = rankMentionCandidates(pool: pool, query: 'be');
        expect(ranked.map((c) => c.uid), contains('uid-3'));
      },
    );

    test('a name that does not contain the query is filtered out', () {
      final ranked = rankMentionCandidates(pool: pool, query: 'zso');
      expect(ranked.map((c) => c.uid), ['uid-2']);
    });

    test(
      'a name STARTING with the query beats one merely containing it — typing '
      '"be" means Bence far more often than it means Devecser',
      () {
        final ranked = rankMentionCandidates(pool: pool, query: 'be');
        expect(ranked.first.uid, 'uid-3');
      },
    );

    test('the signed-in user is never offered their own name', () {
      final ranked = rankMentionCandidates(
        pool: pool,
        query: '',
        selfUid: 'uid-1',
      );
      expect(ranked.map((c) => c.uid), isNot(contains('uid-1')));
    });

    test(
      'a profile with no name is unofferable — there would be nothing to '
      'insert and nothing for the reader to see',
      () {
        final ranked = rankMentionCandidates(pool: pool, query: '');
        expect(ranked.map((c) => c.uid), isNot(contains('uid-nameless')));
      },
    );

    test('the list is capped, so the picker stays a suggestion not a directory', () {
      final many = [
        for (var i = 0; i < 30; i++)
          MentionCandidate(uid: 'uid-$i', displayName: 'Climber $i'),
      ];
      expect(
        rankMentionCandidates(pool: many, query: '').length,
        kMaxMentionSuggestions,
      );
      expect(rankMentionCandidates(pool: many, query: '', limit: 2).length, 2);
    });

    test('matching ignores case, because typing a name does not', () {
      final ranked = rankMentionCandidates(pool: pool, query: 'BOGI');
      expect(ranked.map((c) => c.uid), ['uid-1']);
    });
  });

  group('parseCommentBodySpans', () {
    List<CommentBodySpan> parse(
      String body,
      List<String> uids,
      Map<String, String?> names,
    ) => parseCommentBodySpans(
      body: body,
      mentionedUids: uids,
      displayNameOf: (uid) => names[uid],
    );

    test('a comment that tags nobody is one plain run', () {
      expect(parse('Nice lead!', const [], const {}), [
        const CommentBodySpan.text('Nice lead!'),
      ]);
    });

    test('the mention is split out of the surrounding text', () {
      expect(parse('Nice one @Bogi!', ['uid-1'], {'uid-1': 'Bogi'}), [
        const CommentBodySpan.text('Nice one '),
        const CommentBodySpan.mention(uid: 'uid-1', text: '@Bogi'),
        const CommentBodySpan.text('!'),
      ]);
    });

    test(
      'a climber who has renamed themselves renders under their CURRENT name, '
      'not the one frozen in the body — that is the entire reason mentions are '
      'stored as uids',
      () {
        expect(parse('Nice one @Bogi', ['uid-1'], {'uid-1': 'Bogi Nagy'}), [
          const CommentBodySpan.text('Nice one '),
          const CommentBodySpan.mention(uid: 'uid-1', text: '@Bogi Nagy'),
        ]);
      },
    );

    test(
      'a uid whose profile row has not been pulled yet keeps the literal text '
      'that was typed — still true, still readable, and never a raw uid',
      () {
        final spans = parse('Nice one @Bogi', ['uid-1'], const {'uid-1': null});
        expect(spans, [
          const CommentBodySpan.text('Nice one '),
          const CommentBodySpan.mention(uid: 'uid-1', text: '@Bogi'),
        ]);
        expect(spans.map((s) => s.text).join(), isNot(contains('uid-1')));
      },
    );

    test('two mentions in one comment each resolve to their own name', () {
      expect(
        parse('@Bogi and @Zsofi crushed it', ['uid-1', 'uid-2'], {
          'uid-1': 'Bogi',
          'uid-2': 'Zsofi',
        }),
        [
          const CommentBodySpan.mention(uid: 'uid-1', text: '@Bogi'),
          const CommentBodySpan.text(' and '),
          const CommentBodySpan.mention(uid: 'uid-2', text: '@Zsofi'),
          const CommentBodySpan.text(' crushed it'),
        ],
      );
    });

    test(
      'a longer name wins over a shorter one it starts with, so "@Bogi '
      'Devecser" is not matched as "@Bogi" when both climbers are tagged',
      () {
        final spans = parse('ask @Bogi Devecser', ['uid-1', 'uid-2'], {
          'uid-1': 'Bogi',
          'uid-2': 'Bogi Devecser',
        });
        expect(spans[1], const CommentBodySpan.mention(
          uid: 'uid-2',
          text: '@Bogi Devecser',
        ));
      },
    );

    test(
      'a name match must end at a word boundary — without that "@Bo" claims '
      '"@Bobby" and the two climbers get each other\'s tags',
      () {
        expect(
          parse('hi @Bobby and @Bo', ['uid-bo', 'uid-bobby'], {
            'uid-bo': 'Bo',
            'uid-bobby': 'Bobby',
          }),
          [
            const CommentBodySpan.text('hi '),
            const CommentBodySpan.mention(uid: 'uid-bobby', text: '@Bobby'),
            const CommentBodySpan.text(' and '),
            const CommentBodySpan.mention(uid: 'uid-bo', text: '@Bo'),
          ],
        );
      },
    );

    test(
      'an email address in the body is never turned into a mention — the @ has '
      'to start a word',
      () {
        expect(
          parse('mail bogi@example.test', ['uid-1'], {'uid-1': 'Bogi'}),
          [const CommentBodySpan.text('mail bogi@example.test')],
        );
      },
    );

    test('a bare @ is punctuation, not a tag', () {
      expect(parse('meet @ 6', ['uid-1'], {'uid-1': 'Bogi'}), [
        const CommentBodySpan.text('meet @ 6'),
      ]);
    });

    test(
      'a tagged uid with nothing in the text to tie it to leaves the body '
      'alone rather than inventing a mention',
      () {
        expect(parse('Nice lead!', ['uid-1'], {'uid-1': 'Bogi'}), [
          const CommentBodySpan.text('Nice lead!'),
        ]);
      },
    );

    test('an accented name matches as one token, not up to the first accent', () {
      expect(parse('szép @Zsófi', ['uid-1'], {'uid-1': 'Zsófi'}), [
        const CommentBodySpan.text('szép '),
        const CommentBodySpan.mention(uid: 'uid-1', text: '@Zsófi'),
      ]);
    });

    test('a garbage uid list cannot make the body unreadable', () {
      expect(parse('Nice one @Bogi', const ['', '   '], const {}), [
        const CommentBodySpan.text('Nice one @Bogi'),
      ]);
    });
  });
}
