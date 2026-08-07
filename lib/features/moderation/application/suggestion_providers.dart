import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';
import '../../library/application/library_providers.dart';
import '../data/suggestions_remote.dart';
import '../domain/edit_suggestion.dart';

/// The cloud seam for suggested edits. Overridden in tests with an in-memory
/// fake — never the real one, which would touch the network.
final suggestionsRemoteProvider = Provider<SuggestionsRemote>(
  (ref) => SupabaseSuggestionsRemote(ref.watch(supabaseClientProvider)),
);

/// Open suggestions on topos the signed-in user owns, oldest first.
///
/// Oldest first because a suggestion nobody answers is exactly the
/// abandoned-topo failure C-11 describes, and working the oldest first is what
/// stops the pile becoming permanent.
///
/// Keyed on the uid so signing in as somebody else re-resolves rather than
/// showing the previous account's inbox, and resolves to an empty list when
/// signed out rather than erroring on a question that has no meaning.
final mySuggestionsProvider = FutureProvider.autoDispose<List<EditSuggestion>>((
  ref,
) async {
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return const [];
  final rows = await ref.watch(suggestionsRemoteProvider).fetchForMe();
  return [for (final row in rows) ?EditSuggestion.fromRow(row)];
});

/// Filing suggestions, and answering the ones you receive.
class SuggestionService {
  const SuggestionService(this._ref);

  final Ref _ref;

  /// Files a suggestion. Errors propagate — there is no outbox (decision D-4),
  /// so a failure means nothing was recorded, and somebody who believes they
  /// have offered a correction that never left the device is worse off than
  /// one who was told it failed.
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) => _ref.read(suggestionsRemoteProvider).suggest(
    wallId: wallId,
    kind: kind,
    patch: patch,
    note: note,
    routeId: routeId,
    photoId: photoId,
  );

  /// Accepts a suggestion: APPLIES IT FIRST, then records the decision.
  ///
  /// The order is load-bearing. If the write lands and the mark then fails,
  /// the edit is live and the suggestion stays open — the owner sees it again
  /// and accepting a second time re-applies the same values, which is a no-op.
  /// The other order leaves a suggestion marked accepted with nothing changed,
  /// and nothing anywhere to notice it.
  ///
  /// The write goes through `LibraryCrudRepository` against the owner's OWN
  /// rows, exactly as if they had typed the change themselves — no new write
  /// authority anywhere, which is the whole reason a suggestion is a patch and
  /// not a fork.
  Future<void> accept(EditSuggestion suggestion) async {
    final repo = _ref.read(libraryCrudRepositoryProvider);
    switch (suggestion.kind) {
      case SuggestionKind.topoMetadata:
        await repo.applyWallSuggestion(suggestion.wallId, suggestion.patch);
      case SuggestionKind.routeMetadata:
        final routeId = suggestion.routeId;
        // A route suggestion whose target is gone cannot be applied. Mark it
        // resolved anyway rather than leaving it in the inbox forever — the
        // route it was about no longer exists, so there is nothing to do and
        // nothing to keep asking about.
        if (routeId != null) {
          await repo.applyRouteSuggestion(routeId, suggestion.patch);
        }
      case SuggestionKind.routeGeometry:
        final proposal = suggestion.geometry;
        final photoId = suggestion.photoId;
        // Both are guaranteed present by `EditSuggestion.fromRow`, which drops
        // a geometry row missing either — so reaching this with a null is a
        // bug rather than a user-facing case, and the right response is to
        // resolve it out of the inbox rather than write half a line.
        if (proposal != null && photoId != null) {
          await repo.applyRouteGeometry(
            wallId: suggestion.wallId,
            photoId: photoId,
            points: proposal.points,
            symbols: proposal.symbols,
            routeId: suggestion.routeId,
          );
        }
    }
    await _ref
        .read(suggestionsRemoteProvider)
        .resolve(suggestionId: suggestion.id, accept: true);
    _ref.invalidate(mySuggestionsProvider);
  }

  /// Turns one down. Nothing is written to the topo.
  Future<void> reject(EditSuggestion suggestion, {String? note}) async {
    await _ref
        .read(suggestionsRemoteProvider)
        .resolve(suggestionId: suggestion.id, accept: false, note: note);
    _ref.invalidate(mySuggestionsProvider);
  }
}

final suggestionServiceProvider = Provider<SuggestionService>(
  SuggestionService.new,
);
