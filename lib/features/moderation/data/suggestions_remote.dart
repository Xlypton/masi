import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/edit_suggestion.dart';

/// The cloud seam for suggested edits (community editing phase 7a / C-5).
abstract class SuggestionsRemote {
  /// Files a suggestion and returns its id.
  ///
  /// Rate-limited server-side: three OPEN per author per topo (someone with
  /// three unanswered suggestions on one topo does not need a fourth, they
  /// need the owner to look), and twenty per author per day. Throws on a
  /// private topo, an unknown kind, and any field off the whitelist — the
  /// whole patch is refused rather than partly applied, because a suggestion
  /// that silently drops half of what its author wrote is worse than one that
  /// is turned down.
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
  });

  /// Open suggestions on topos the signed-in user OWNS, oldest first.
  ///
  /// Throws rather than swallowing: an inbox that renders empty because the
  /// session expired says "nobody has offered to help", which is the message
  /// most likely to make an owner stop looking.
  Future<List<Map<String, dynamic>>> fetchForMe({int limit});

  /// Records the owner's decision. Does NOT apply the patch — the owner's own
  /// client does that against its own rows, which is the whole point of a
  /// patch over a fork.
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  });
}

class SupabaseSuggestionsRemote implements SuggestionsRemote {
  SupabaseSuggestionsRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'suggest_edit',
      params: {
        'wall_id': wallId,
        'kind': kind.wire,
        'patch': patch,
        'note': note,
        'route_id': routeId,
      },
    );
    return result is String ? result : '';
  }

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async {
    final rows = await _client.rpc<dynamic>(
      'suggestions_for_me',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async {
    final result = await _client.rpc<dynamic>(
      'resolve_suggestion',
      params: {
        'suggestion_id': suggestionId,
        'accept': accept,
        'note': note,
      },
    );
    return result is String ? result : (accept ? 'accepted' : 'rejected');
  }
}
