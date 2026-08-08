import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/application/profile_providers.dart';
import '../domain/comment_mentions.dart';

/// The climbers the comment composer's `@` picker may offer, before any query
/// or thread-participant ranking is applied — see [rankMentionCandidates],
/// which does both and is where the reasoning about WHO belongs in a picker is
/// written down.
///
/// A local Drift stream, deliberately: this app is local-first, and a mention
/// picker that hit the network on every keystroke would be unusable at a crag
/// and wrong in shape besides. `profiles` is not a global directory — it holds
/// the rows sync has pulled for people whose content this device has seen.
///
/// `autoDispose` because the pool is only wanted while a composer is on screen;
/// keeping a `profiles`-wide watch alive app-lifetime for a picker nobody has
/// opened is exactly the leak `profileDisplayNameProvider` avoids for the same
/// reason.
final mentionCandidatePoolProvider =
    StreamProvider.autoDispose<List<MentionCandidate>>((ref) {
      return ref.watch(profileRepositoryProvider).watchNamedProfiles().map(
        (rows) => [
          for (final row in rows)
            // `displayName` is non-null by the query's own WHERE, but the
            // trim/skip here is what keeps a row of pure whitespace — which SQL
            // considers a perfectly good name — out of the picker.
            if ((row.displayName ?? '').trim().isNotEmpty)
              MentionCandidate(
                uid: row.id,
                displayName: row.displayName!.trim(),
                avatarUrl: row.avatarUrl,
              ),
        ],
      );
    });
