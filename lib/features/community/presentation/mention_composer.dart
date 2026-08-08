import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../account/application/auth_providers.dart';
import '../application/mention_providers.dart';
import '../domain/comment_mentions.dart';

/// The comment composer's text controller, extended to remember WHO the draft
/// tags as well as what it says.
///
/// A [TextEditingController] subclass rather than a separate piece of state
/// beside one, because the two are inseparable: the mention list is only
/// meaningful relative to the text (a mention the user has since deleted is not
/// a mention), the picker's open/closed state is a function of the caret, and
/// every screen that owns a composer already owns and disposes a controller.
/// Splitting them left two things that had to be kept in step by hand, and the
/// step that gets missed is always `clear()`.
class MentionComposerController extends TextEditingController {
  MentionComposerController({super.text});

  final List<PendingMention> _mentions = [];

  /// The mentions inserted into this draft so far — including any whose text
  /// the user has since deleted. [mentionedUids] is what filters those out.
  List<PendingMention> get mentions => List.unmodifiable(_mentions);

  /// The `@…` the caret is currently in, or `null` when the picker should be
  /// closed. See [activeMentionQuery] for the rules.
  ///
  /// A non-collapsed selection closes it: while text is selected the user is
  /// deleting or replacing, not typing a name.
  MentionQuery? get activeQuery {
    final currentSelection = selection;
    if (!currentSelection.isValid || !currentSelection.isCollapsed) return null;
    return activeMentionQuery(text, currentSelection.baseOffset);
  }

  /// The uids to store with this comment: the inserted mentions still present
  /// in the text, in the order they appear there.
  List<String> get mentionedUids => mentionedUidsInBody(text, _mentions);

  /// Replaces the in-progress `@…` with [candidate]'s name and records the uid.
  ///
  /// A trailing space is part of the insertion on purpose — without it the
  /// caret sits at the end of the name it just completed, the query is still
  /// active, and the picker reopens over the name the user has finished
  /// choosing.
  ///
  /// A no-op when there is no active query, so a stale tap on a picker that has
  /// closed cannot splice a name into the middle of a sentence.
  void insertMention(MentionCandidate candidate) {
    final query = activeQuery;
    if (query == null) return;
    final name = candidate.displayName.trim();
    if (name.isEmpty) return;

    final before = text.substring(0, query.start);
    final after = text.substring(query.start + 1 + query.query.length);
    final inserted = '@$name ';
    // Re-picking the same person at the same name must not stack duplicate
    // entries; the stored array dedupes anyway, but the pending list is also
    // what `mentionedUids` scans, and a shorter one is a cheaper scan and a
    // clearer thing to debug.
    _mentions.removeWhere((m) => m.uid == candidate.uid && m.insertedName == name);
    _mentions.add(PendingMention(uid: candidate.uid, insertedName: name));

    value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(
        offset: before.length + inserted.length,
      ),
    );
  }

  /// Clears the text AND the mentions — posting a comment must not leave the
  /// previous draft's tags armed for the next one.
  @override
  void clear() {
    _mentions.clear();
    super.clear();
  }
}

/// The inline `@`-mention picker that sits directly above a comment composer:
/// a short list of climbers, filtered live as the user keeps typing, which
/// disappears the moment the caret leaves the `@…`.
///
/// Rendered unconditionally by the composer and collapsing to nothing when
/// there is no active query, rather than being conditionally inserted by each
/// screen: two screens deciding for themselves when a picker is open is how the
/// two threads drift apart, which is the same reason `CommentRow` is one widget.
class MentionSuggestions extends ConsumerWidget {
  const MentionSuggestions({
    super.key,
    required this.controller,
    required this.keyPrefix,
    this.participantUids = const {},
  });

  final MentionComposerController controller;

  /// Prefixes this picker's keys as `<keyPrefix>-mention-…`, matching the
  /// prefix its thread already gives [CommentRow].
  final String keyPrefix;

  /// The uids already involved in this thread — its comment authors, and the
  /// owner of whatever is being discussed. They rank first; see
  /// [rankMentionCandidates] for why.
  final Set<String> participantUids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    // The pool is a stream that may not have answered yet, and an empty list is
    // the right answer for both "still loading" and "nobody to offer" — a
    // picker is a suggestion, so it has no loading or error state of its own.
    final pool = ref.watch(mentionCandidatePoolProvider).value ?? const [];
    // §1c: the single local-data uid door.
    final selfUid = ref.watch(effectiveUidProvider);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, _, _) {
        final query = controller.activeQuery;
        if (query == null) return const SizedBox.shrink();
        final matches = rankMentionCandidates(
          pool: pool,
          query: query.query,
          participantUids: participantUids,
          selfUid: selfUid,
        );
        // Nothing matched: collapse rather than show an empty box. "No such
        // climber" is not news to somebody halfway through typing a name.
        if (matches.isEmpty) return const SizedBox.shrink();

        return Container(
          key: Key('$keyPrefix-mention-suggestions'),
          margin: const EdgeInsets.only(bottom: MasiSpacing.sm),
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(MasiRadii.card),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A plain Column, not a ListView: the composer lives inside a
              // scroll view on both threads, and a nested scrollable there
              // needs a bounded height it cannot get. The list is capped at
              // `kMaxMentionSuggestions` rows, so it never needs to scroll.
              for (final candidate in matches)
                InkWell(
                  key: Key('$keyPrefix-mention-suggestion-${candidate.uid}'),
                  onTap: () => controller.insertMention(candidate),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MasiSpacing.md,
                      vertical: MasiSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        MasiAvatar(
                          avatarUrl: candidate.avatarUrl,
                          // Same rule as the comment rows: a thread knows who
                          // someone is without knowing their address.
                          email: null,
                          displayName: candidate.displayName,
                          radius: 14,
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Expanded(
                          child: Text(
                            candidate.displayName,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.ink,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
