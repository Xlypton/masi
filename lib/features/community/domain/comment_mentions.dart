import 'dart:convert';

/// Everything about tagging a climber in a comment that does NOT need Flutter,
/// Drift or Riverpod: the storage codec for `Comments.mentionedUids`, the
/// composer's `@`-query detection, the candidate ranking, and the parse that
/// turns a stored body plus a uid list back into styled spans.
///
/// It all lives here, pure and importable, because every sharp edge in this
/// feature is in exactly these functions — a body somebody typed by hand, a
/// JSON column that a future server or an older client may have written, a
/// display name that has changed since the comment was posted. Widgets are a
/// bad place to test any of that.

/// The most candidates the composer's inline picker will ever offer.
///
/// Six is about one thumb-reach of list. The cap is not a performance guard
/// (the pool is a local table with, realistically, tens of rows) — it is there
/// so the picker stays a suggestion rather than a directory the user has to
/// read.
const int kMaxMentionSuggestions = 6;

/// The longest `@…` fragment still treated as an in-progress mention query.
///
/// Without a bound, a stray `@` early in a paragraph keeps the picker armed for
/// the rest of the comment, and every keystroke re-ranks candidates against a
/// query that is plainly not a name.
const int kMaxMentionQueryLength = 32;

/// A climber the composer can offer for tagging: a local `profiles` row that
/// actually has a name to show.
class MentionCandidate {
  const MentionCandidate({
    required this.uid,
    required this.displayName,
    this.avatarUrl,
  });

  /// The Supabase Auth uid — what gets stored, and the only stable reference.
  final String uid;

  /// The display name as it reads RIGHT NOW. It is what gets inserted into the
  /// body, and it is expected to go stale there; see [parseCommentBodySpans].
  final String displayName;

  final String? avatarUrl;

  @override
  bool operator ==(Object other) =>
      other is MentionCandidate &&
      other.uid == uid &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(uid, displayName, avatarUrl);

  @override
  String toString() =>
      'MentionCandidate(uid: $uid, displayName: $displayName, '
      'avatarUrl: $avatarUrl)';
}

/// A mention the composer has already inserted into the draft: the uid it
/// stands for, and the exact text it wrote into the body.
///
/// The inserted text is remembered ONLY so that [mentionedUidsInBody] can tell
/// whether the mention is still in the draft when the user posts. Someone who
/// picks a name and then backspaces it away has not tagged that person, and a
/// uid left behind in the column would notify them for a mention nobody can
/// see.
class PendingMention {
  const PendingMention({required this.uid, required this.insertedName});

  final String uid;

  /// The display name as inserted, WITHOUT the leading `@`.
  final String insertedName;

  @override
  bool operator ==(Object other) =>
      other is PendingMention &&
      other.uid == uid &&
      other.insertedName == insertedName;

  @override
  int get hashCode => Object.hash(uid, insertedName);

  @override
  String toString() =>
      'PendingMention(uid: $uid, insertedName: $insertedName)';
}

/// One piece of a comment body as it should be drawn: either plain text
/// ([uid] `null`) or a mention of [uid] rendered as [text].
class CommentBodySpan {
  const CommentBodySpan.text(this.text) : uid = null;
  const CommentBodySpan.mention({required String this.uid, required this.text});

  /// `null` for a plain-text run.
  final String? uid;

  /// Exactly what to paint — for a mention this is `'@' + the LIVE display
  /// name`, not the text frozen in the body.
  final String text;

  bool get isMention => uid != null;

  @override
  bool operator ==(Object other) =>
      other is CommentBodySpan && other.uid == uid && other.text == text;

  @override
  int get hashCode => Object.hash(uid, text);

  @override
  String toString() => 'CommentBodySpan(uid: $uid, text: $text)';
}

/// An in-progress `@…` the caret is currently sitting in: where the `@` is,
/// and what has been typed after it so far.
typedef MentionQuery = ({int start, String query});

/// Encodes [uids] for the `Comments.mentionedUids` column, or `null` when
/// nothing is tagged.
///
/// `null` rather than `'[]'` for the empty case on purpose: almost every
/// comment tags nobody, and a column full of two-character JSON literals costs
/// a byte on every row and every sync push to say exactly what an absent value
/// already says. Callers reading it back cannot tell the two apart anyway —
/// [decodeMentionedUids] maps both to the empty list.
///
/// Blank entries are dropped and duplicates collapse to their first
/// occurrence, so the stored array is always the tidy form even when the
/// caller's list is not.
String? encodeMentionedUids(Iterable<String> uids) {
  final cleaned = _normalizeUids(uids);
  if (cleaned.isEmpty) return null;
  return jsonEncode(cleaned);
}

/// Decodes the `Comments.mentionedUids` column into the uids it names.
///
/// **Total by construction.** This value arrives from a text column that a
/// server, an older client, a hand-run migration or a corrupted sync could all
/// have written, and it is read on the render path of every comment in a
/// thread. Every failure — malformed JSON, a JSON object where an array was
/// expected, numbers or nulls among the elements, blank strings, duplicates —
/// degrades to the sanest list it can build rather than throwing. A comment
/// whose mention data is garbage must still be readable; a thread that throws
/// while painting is a far worse outcome than a mention that renders as plain
/// text.
List<String> decodeMentionedUids(String? raw) {
  if (raw == null) return const [];
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];

  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }
  // A JSON object, a bare string or a number are all "not a list of uids".
  // Salvaging something from them would be guessing at a writer this app does
  // not have.
  if (decoded is! List) return const [];

  // Non-string elements are skipped rather than stringified: `"42"` as a uid
  // would key a profile lookup that can never match, which is worse than the
  // mention simply not rendering.
  return _normalizeUids(decoded.whereType<String>());
}

/// Trim, drop blanks, drop duplicates, keep order.
List<String> _normalizeUids(Iterable<String> uids) {
  final seen = <String>{};
  final out = <String>[];
  for (final uid in uids) {
    final trimmed = uid.trim();
    if (trimmed.isEmpty) continue;
    if (!seen.add(trimmed)) continue;
    out.add(trimmed);
  }
  return out;
}

/// The `@…` fragment [caret] is sitting in, or `null` when the caret is not in
/// one and the picker should be closed.
///
/// The rules, and what each is protecting against:
///  * The `@` must start a word — `climber@example.test` is an address, not a
///    tag, and popping a picker over one is the sort of thing that makes a
///    composer feel possessed.
///  * A newline between the `@` and the caret ends it. So does a second space:
///    display names here are commonly `First Last`, so one space has to be
///    allowed, but "everything after the last `@` in the paragraph" is not a
///    name and never resolves to one.
///  * [kMaxMentionQueryLength] bounds it, for the same reason.
MentionQuery? activeMentionQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;

  var spaces = 0;
  for (var i = caret - 1; i >= 0; i--) {
    final ch = text[i];
    if (ch == '\n' || ch == '\r') return null;
    if (caret - i > kMaxMentionQueryLength) return null;
    if (ch == ' ') {
      spaces++;
      if (spaces > 1) return null;
      continue;
    }
    if (ch != '@') continue;
    if (i > 0 && _isWordChar(text[i - 1])) return null;
    return (start: i, query: text.substring(i + 1, caret));
  }
  return null;
}

/// The uids to actually store for a draft: those [pending] mentions whose
/// inserted text is STILL in [body], in the order they appear there.
///
/// Two jobs, both of which the render side depends on. It prunes mentions the
/// user typed over or deleted (see [PendingMention]), and it puts the stored
/// array in body order, which is what lets [parseCommentBodySpans] fall back to
/// matching mentions positionally when a name no longer matches.
List<String> mentionedUidsInBody(String body, Iterable<PendingMention> pending) {
  final hits = <({int at, String uid})>[];
  for (final mention in pending) {
    final name = mention.insertedName.trim();
    if (name.isEmpty) continue;
    final at = body.indexOf('@$name');
    if (at < 0) continue;
    hits.add((at: at, uid: mention.uid));
  }
  hits.sort((a, b) => a.at.compareTo(b.at));
  return _normalizeUids([for (final hit in hits) hit.uid]);
}

/// The climbers to offer for [query], best first, capped at [limit].
///
/// **Who is in [pool], and why it is not everybody.** The pool is the local
/// `profiles` table — which is not a directory of the app's users but the set
/// of people whose rows sync has already pulled onto this device, i.e. people
/// whose topos, ascents or comments this user has actually seen. That is
/// already a far better answer than a server-side search, and it is the
/// local-first one: no network call per keystroke, and the picker works at a
/// crag with no signal.
///
/// **Why [participantUids] rank first.** Within that pool the overwhelmingly
/// likely target is somebody already in the thread you are typing in — the
/// climber whose ascent it is, or whoever you are replying to. Everyone else is
/// offered underneath, because restricting the picker to participants outright
/// would make the obvious case (tagging the friend you climbed with, who has
/// not commented yet) impossible, and there is no other way to tag them.
///
/// [selfUid] is excluded: tagging yourself is never what the `@` was for, and
/// leaving yourself in costs the top slot in your own threads.
List<MentionCandidate> rankMentionCandidates({
  required Iterable<MentionCandidate> pool,
  required String query,
  Set<String> participantUids = const {},
  String? selfUid,
  int limit = kMaxMentionSuggestions,
}) {
  if (limit <= 0) return const [];
  final needle = query.trim().toLowerCase();

  final scored = <({MentionCandidate candidate, int rank, String sortKey})>[];
  final seen = <String>{};
  for (final candidate in pool) {
    final name = candidate.displayName.trim();
    // A nameless profile is unofferable: there would be nothing to insert into
    // the body and nothing for the reader to see.
    if (name.isEmpty) continue;
    if (candidate.uid == selfUid) continue;
    if (!seen.add(candidate.uid)) continue;

    final lower = name.toLowerCase();
    if (needle.isNotEmpty && !lower.contains(needle)) continue;

    // A prefix hit beats a mid-name hit: typing "bo" means Bogi far more often
    // than it means Sebastian.
    final isPrefix = needle.isEmpty || lower.startsWith(needle);
    final isParticipant = participantUids.contains(candidate.uid);
    final rank = (isParticipant ? 0 : 2) + (isPrefix ? 0 : 1);
    scored.add((candidate: candidate, rank: rank, sortKey: lower));
  }

  scored.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    // Alphabetical inside a tier, so the list does not reshuffle between builds
    // for reasons the user cannot see.
    return a.sortKey.compareTo(b.sortKey);
  });

  return [
    for (final entry in scored.take(limit)) entry.candidate,
  ];
}

/// Splits [body] into the runs to draw, resolving each mention's text through
/// [displayNameOf] rather than trusting what is written in the body.
///
/// **Why the body text cannot be trusted.** The composer writes `@Bogi` into
/// the body and stores the uid alongside it, and display names are editable
/// (#18). The text is therefore a description of who somebody was the day the
/// comment was posted; the uid is the reference. Resolving through the uid is
/// the entire reason the column exists.
///
/// **How a uid is matched to a place in the text.** In order:
///  1. By name. Each mentioned uid's LIVE name is looked for after an `@` at a
///     word boundary, longest name first so `@Bogi Devecser` is not matched as
///     `@Bogi` when both are tagged. This is the case that covers essentially
///     every comment: nobody has renamed themselves between the post and the
///     read.
///  2. By position. Uids no name-match claimed are handed to the leftover
///     `@word` tokens in body order — which works because
///     [mentionedUidsInBody] stores the array in body order. This is what makes
///     a rename still render the new name.
///
/// A mention whose uid resolves to no name at all (the profile row has not been
/// pulled yet) keeps the literal text that was typed. That is the graceful
/// degradation: the reader sees the name the author actually wrote, which is
/// still true and still readable. What never happens is a raw uid on screen —
/// the same rule the identity lines follow.
///
/// The alternative considered and rejected was writing markers into the body
/// (`@[uid]`, the way chat apps do it). It would make matching exact, and it
/// would also mean the body column — which the server stores verbatim and older
/// clients render verbatim — reads as machine noise everywhere outside this
/// parse.
List<CommentBodySpan> parseCommentBodySpans({
  required String body,
  required List<String> mentionedUids,
  required String? Function(String uid) displayNameOf,
}) {
  if (body.isEmpty) return const [];
  final uids = _normalizeUids(mentionedUids);
  if (uids.isEmpty) return [CommentBodySpan.text(body)];

  final named = <({String uid, String name})>[];
  for (final uid in uids) {
    final name = displayNameOf(uid)?.trim();
    if (name == null || name.isEmpty) continue;
    named.add((uid: uid, name: name));
  }
  named.sort((a, b) => b.name.length.compareTo(a.name.length));

  final tokens = _tokenizeMentions(body, named);
  _bindLeftoverUids(tokens, uids);

  final spans = <CommentBodySpan>[];
  var cursor = 0;
  for (final token in tokens) {
    final uid = token.uid;
    // An unbound token is ordinary text somebody typed with an `@` in it; it
    // stays part of the surrounding run rather than becoming a span of its own.
    if (uid == null) continue;
    if (token.start > cursor) {
      spans.add(CommentBodySpan.text(body.substring(cursor, token.start)));
    }
    final live = displayNameOf(uid)?.trim();
    spans.add(
      CommentBodySpan.mention(
        uid: uid,
        text: (live == null || live.isEmpty)
            ? body.substring(token.start, token.end)
            : '@$live',
      ),
    );
    cursor = token.end;
  }
  if (cursor < body.length) {
    spans.add(CommentBodySpan.text(body.substring(cursor)));
  }
  return spans;
}

class _MentionToken {
  _MentionToken({required this.start, required this.end, this.uid});

  final int start;
  final int end;
  String? uid;
}

/// Finds every `@…` in [body] that could be a mention, binding the ones whose
/// text matches a live name in [named].
List<_MentionToken> _tokenizeMentions(
  String body,
  List<({String uid, String name})> named,
) {
  final tokens = <_MentionToken>[];
  var i = 0;
  while (i < body.length) {
    if (body[i] != '@' || (i > 0 && _isWordChar(body[i - 1]))) {
      i++;
      continue;
    }

    String? uid;
    var end = -1;
    for (final candidate in named) {
      final stop = i + 1 + candidate.name.length;
      if (stop > body.length) continue;
      if (body.substring(i + 1, stop).toLowerCase() !=
          candidate.name.toLowerCase()) {
        continue;
      }
      // The match must end at a word boundary, or `@Bo` claims `@Bob`.
      if (stop < body.length && _isWordChar(body[stop])) continue;
      uid = candidate.uid;
      end = stop;
      break;
    }

    if (uid == null) {
      end = i + 1;
      while (end < body.length && _isWordChar(body[end])) {
        end++;
      }
      // A bare `@` with nothing after it is punctuation, not a tag.
      if (end == i + 1) {
        i++;
        continue;
      }
    }

    tokens.add(_MentionToken(start: i, end: end, uid: uid));
    i = end;
  }
  return tokens;
}

/// Hands each uid no name-match claimed to the next unbound token, in body
/// order — the rename path described in [parseCommentBodySpans].
void _bindLeftoverUids(List<_MentionToken> tokens, List<String> uids) {
  final bound = {for (final token in tokens) if (token.uid != null) token.uid};
  final leftovers = [for (final uid in uids) if (!bound.contains(uid)) uid];
  if (leftovers.isEmpty) return;
  var next = 0;
  for (final token in tokens) {
    if (token.uid != null) continue;
    if (next >= leftovers.length) return;
    token.uid = leftovers[next++];
  }
}

/// Letters, digits and `_`, in any script — Hungarian names are the local
/// case, but ASCII-only `\w` would break every accented name anywhere.
final RegExp _wordCharPattern = RegExp(r'[\p{L}\p{N}_]', unicode: true);

bool _isWordChar(String ch) => _wordCharPattern.hasMatch(ch);
