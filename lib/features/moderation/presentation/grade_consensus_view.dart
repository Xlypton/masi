import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../application/community_facts_providers.dart';
import '../domain/community_facts.dart';

/// What the community reckons a route goes at, rendered BESIDE the author's
/// own grade (community editing phase 4 / R-1).
///
/// Never replaces the author's grade and never rewrites the route. The
/// author's number stays authoritative for display and for filtering; this is
/// a second opinion shown next to it, which is what makes the whole feature
/// safe to leave ungated.
///
/// Renders nothing below [kMinOpinionsForConsensus] — the count alone is real
/// information, but "the consensus is 7a (n=1)" is a lie with a number
/// attached, and would let one passer-by appear to overrule a first
/// ascensionist.
class GradeConsensusChip extends ConsumerWidget {
  const GradeConsensusChip({
    super.key,
    required this.routeId,
    required this.system,
    this.authorGrade,
  });

  final String routeId;

  /// The ladder to render the consensus on. Cross-system by construction:
  /// three UIAA opinions read back as a French grade, because they were
  /// stored on the shared scale.
  final GradeSystem system;

  /// The author's own grade, if the route has one.
  final String? authorGrade;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);

    final authorSortKey =
        (authorGrade != null && isValidGrade(system, authorGrade!))
        ? gradeSortKey(system, authorGrade!)
        : null;

    final consensus = ref
        .watch(
          routeGradeConsensusProvider(
            ConsensusRequest(routeId: routeId, authorSortKey: authorSortKey),
          ),
        )
        .asData
        ?.value;

    final label = consensus?.displayGrade(system);
    if (consensus == null || label == null) return const SizedBox.shrink();

    // Only tinted when the community meaningfully disagrees. A chip that is
    // always coloured is a chip nobody reads, and most of the time the
    // consensus simply confirms the author.
    final disagrees = consensus.disagreesWithAuthor;
    final tint = disagrees ? colors.gradeHard : colors.ink2;

    return Container(
      key: Key('grade-consensus-$routeId'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label · ${consensus.count}',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: tint, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// How far either side of the author's grade the opinion picker offers.
///
/// The picker is bounded rather than showing the whole ladder because a
/// 25-row action sheet is unusable on a phone, and because the realistic
/// claim is "this is a bit stiffer than stated", not "this 4a is actually
/// 8c". A route with NO author grade falls back to the full ladder, since
/// there is no anchor to window around.
const int kGradeOpinionWindow = 5;

/// The grades offered for [system] around [authorGrade].
///
/// At the ends of the ladder the window SHRINKS rather than sliding, so the
/// hardest and softest grades stay offered — there is simply nothing beyond
/// them to offer instead.
///
/// Exposed (rather than inlined into the sheet) so the windowing is testable
/// without pumping a widget: off-by-ones at the ladder ends are easy to write
/// and would silently make some grades unstatable.
List<String> gradeOpinionOptions(GradeSystem system, String? authorGrade) {
  final ladder = gradeOptions(system);
  if (authorGrade == null || !isValidGrade(system, authorGrade)) {
    return ladder;
  }
  final anchor = ladder.indexOf(normalizeGrade(system, authorGrade));
  if (anchor < 0) return ladder;

  final from = (anchor - kGradeOpinionWindow).clamp(0, ladder.length);
  final to = (anchor + kGradeOpinionWindow + 1).clamp(0, ladder.length);
  return ladder.sublist(from, to);
}

/// Lets anyone signed in state what they think a route goes at.
///
/// Returns the chosen grade, or `null` if they backed out. One opinion per
/// person per route: submitting REPLACES rather than stacks (the server
/// upserts on `(routeId, authorId)`), so changing your mind is a first-class
/// action rather than a second vote.
Future<String?> showGradeOpinionPicker(
  BuildContext context, {
  required GradeSystem system,
  required String routeLabel,
  String? authorGrade,
  String? currentOpinion,
}) => showMasiActionSheet<String>(
  context,
  sheetKey: const Key('grade-opinion-sheet'),
  title: 'What does $routeLabel go at?',
  message: currentOpinion == null
      ? "Shown next to the first ascensionist's grade, never instead of it."
      : 'You said $currentOpinion. Choosing again replaces that.',
  actions: [
    for (final grade in gradeOpinionOptions(system, authorGrade))
      MasiSheetAction(
        key: Key('grade-opinion-$grade'),
        label: grade == authorGrade ? '$grade (as stated)' : grade,
        value: grade,
      ),
  ],
);
