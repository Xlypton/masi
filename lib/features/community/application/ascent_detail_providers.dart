import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logbook/application/ascents_providers.dart';
import '../../logbook/data/ascents_repository.dart';

/// Resolves ONE [SharedAscentEntry] by its [ascentId] out of
/// [sharedAscentsProvider]'s cross-owner feed (Feature #12, public opt-in
/// ascent logs) — the single-ascent read `AscentDetailScreen` needs.
///
/// Deliberately reuses the existing feed provider (a `firstWhere`-style
/// lookup) rather than adding a new by-id repository method:
/// `sharedAscentsProvider` already streams every `visibility == 'shared'`
/// ascent joined to its route/wall, and a public/shared-ascent link is
/// exactly (and only) that audience — a second DB round trip for the same
/// data would be redundant, and it keeps `ascents_repository.dart` untouched
/// for other Wave-3 agents.
///
/// Resolves to `null` (never an error) once loaded if [ascentId] isn't found
/// in that list — e.g. the ascent hasn't synced down to this device yet, was
/// un-shared, or was deleted — so the screen can render a graceful
/// not-found state instead of crashing.
final ascentDetailProvider =
    Provider.family<AsyncValue<SharedAscentEntry?>, String>((ref, ascentId) {
      final asyncEntries = ref.watch(sharedAscentsProvider);
      return asyncEntries.whenData((entries) {
        for (final entry in entries) {
          if (entry.ascentId == ascentId) return entry;
        }
        return null;
      });
    });
