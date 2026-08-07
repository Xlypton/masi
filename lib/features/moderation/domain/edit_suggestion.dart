/// Suggested edits to a published topo (community editing phases 7a and 7b /
/// C-5).
///
/// Two shapes, and they are not variations on each other. A METADATA
/// suggestion is `{field: newValue}` and reads as a sentence — the owner can
/// decide from the text alone. A GEOMETRY suggestion is a line in percent
/// space, and nobody can review a line by reading coordinates (§C-5b), so it
/// carries the photo it was drawn on and is decided from a picture.
library;

import 'geometry_proposal.dart';

enum SuggestionKind {
  topoMetadata,
  routeMetadata,
  routeGeometry;

  String get wire => switch (this) {
    SuggestionKind.topoMetadata => 'topo.metadata',
    SuggestionKind.routeMetadata => 'route.metadata',
    SuggestionKind.routeGeometry => 'route.geometry',
  };

  static SuggestionKind? fromWire(String? raw) => switch (raw) {
    'topo.metadata' => SuggestionKind.topoMetadata,
    'route.metadata' => SuggestionKind.routeMetadata,
    'route.geometry' => SuggestionKind.routeGeometry,
    _ => null,
  };

  /// Fields this kind may propose, mirroring `public.suggestion_fields()`.
  ///
  /// Kept in step with the server by [kSuggestableFields] below rather than by
  /// hope: the server refuses anything off its own list, so a client list that
  /// drifted wider would simply produce errors the user cannot act on, and one
  /// that drifted narrower would hide a field that works.
  List<SuggestableField> get fields => switch (this) {
    SuggestionKind.topoMetadata => const [
      SuggestableField.name,
      SuggestableField.latitude,
      SuggestableField.longitude,
    ],
    SuggestionKind.routeMetadata => const [
      SuggestableField.routeName,
      SuggestableField.description,
      SuggestableField.betaVideoUrl,
    ],
    // Empty on purpose, and not an oversight: a line is not a value anybody
    // types. Geometry never goes through the field picker — it is drawn on a
    // canvas and reviewed as a picture.
    SuggestionKind.routeGeometry => const [],
  };
}

/// One proposable field.
///
/// Note what is ABSENT, because the omissions are the design.
///
/// **Grade** is not here. Phase 4 already lets anyone state a grade opinion
/// with no approval step at all and renders the community consensus beside
/// the owner's grade — strictly better than asking the owner's permission to
/// disagree with them about a grade. Two mechanisms for one job, with
/// different politics, would be worse than either.
///
/// **Access state** is not here. It is owner-writable and inheriting (phase
/// 2), and a reader who believes a crag is closed has the "access problem"
/// report (phase 6b), which reaches a moderator rather than waiting on the
/// owner — who may be exactly the person who has not noticed.
///
/// **Stars** is not here. A quality rating is an opinion, not a fact about the
/// world to be corrected, and opinions belong in the facts layer if anywhere.
enum SuggestableField {
  name(wire: 'name', label: 'Topo name'),
  latitude(wire: 'latitude', label: 'Latitude', isNumeric: true),
  longitude(wire: 'longitude', label: 'Longitude', isNumeric: true),
  routeName(wire: 'name', label: 'Route name'),
  description(wire: 'description', label: 'Description', isLong: true),
  betaVideoUrl(wire: 'betaVideoUrl', label: 'Beta video link');

  const SuggestableField({
    required this.wire,
    required this.label,
    this.isNumeric = false,
    this.isLong = false,
  });

  /// The column name. [name] and [routeName] deliberately share `'name'` —
  /// they are the same column on different tables, and the enum splits them
  /// only so the picker can say which one it means.
  final String wire;
  final String label;
  final bool isNumeric;
  final bool isLong;
}

/// Every wire field the server will accept, by kind. Used to validate a patch
/// before sending it, so a rejected suggestion is caught here rather than
/// after a round trip.
const Map<String, List<String>> kSuggestableFields = {
  'topo.metadata': ['name', 'latitude', 'longitude'],
  'route.metadata': ['name', 'description', 'betaVideoUrl', 'style', 'styleTagsJson'],
  'route.geometry': ['points', 'symbols'],
};

/// One suggestion, as its target's owner sees it.
class EditSuggestion {
  const EditSuggestion({
    required this.id,
    required this.wallId,
    required this.wallName,
    required this.kind,
    required this.patch,
    required this.createdAt,
    required this.isStale,
    this.routeId,
    this.routeName,
    this.photoId,
    this.authorId,
    this.authorName,
    this.note,
  });

  final String id;
  final String wallId;
  final String wallName;
  final SuggestionKind kind;

  /// `{field: newValue}`. Every key is on [kSuggestableFields] — the server
  /// refuses the whole patch otherwise, so a stored one cannot contain a field
  /// this app does not know how to apply.
  final Map<String, Object?> patch;

  final int createdAt;

  /// Whether the topo changed after this was written (C-5, Guardrails).
  ///
  /// Not a blocker — the owner may well still want the fix — but the
  /// difference between "somebody suggests renaming this to X" and "somebody
  /// suggested renaming this to X before you renamed it yourself" is the whole
  /// question when deciding.
  final bool isStale;

  final String? routeId;
  final String? routeName;

  /// The photo a geometry proposal was drawn on (§C-5b), and null for every
  /// metadata suggestion. Points are percent-space fractions of THIS image,
  /// so rendering or applying them against any other one is nonsense — the
  /// server refuses a geometry suggestion that does not name a live photo of
  /// the same topo.
  final String? photoId;

  final String? authorId;
  final String? authorName;
  final String? note;

  /// Attribution is most of the reward for contributing, and it costs one
  /// column (C-5). Never a raw uid — that is an identifier, not a name.
  String get authorLabel => authorName ?? 'Someone';

  String get targetLabel =>
      routeName?.trim().isNotEmpty == true ? routeName! : wallName;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(createdAt);

  /// The proposed line, or null for a metadata suggestion.
  ///
  /// Recomputed on read rather than cached: a suggestion is decided once and
  /// then gone, so nothing here is on a path hot enough to trade clarity for.
  GeometryProposal? get geometry => kind == SuggestionKind.routeGeometry
      ? GeometryProposal.fromPatch(patch)
      : null;

  /// Whether this proposes a line that does not exist yet, rather than
  /// replacing one that does. Both are geometry; only one is destructive if
  /// the owner accepts it without looking.
  bool get isNewLine =>
      kind == SuggestionKind.routeGeometry && routeId == null;

  /// A one-line "field: old → new" summary is impossible from this row alone —
  /// the patch carries the proposed value, not the current one — so this
  /// renders only what was proposed. The owner is looking at their own topo
  /// and knows what it says now.
  ///
  /// EMPTY for geometry, which is the point of §C-5b's third requirement:
  /// "nobody can review a line by reading coordinates". Printing
  /// `points: [Offset(0.41, 0.72), …]` would technically render the patch and
  /// tell the owner nothing they could decide on. The inbox draws it instead.
  List<({String label, String value})> get changes =>
      kind == SuggestionKind.routeGeometry
      ? const []
      : [
          for (final entry in patch.entries)
            (label: _labelFor(entry.key), value: '${entry.value}'),
        ];

  String _labelFor(String wire) {
    for (final field in kind.fields) {
      if (field.wire == wire) return field.label;
    }
    return wire;
  }

  /// Returns null for a row this client cannot act on — an unknown kind, or a
  /// patch that is not an object. Dropped rather than shown: an owner cannot
  /// sensibly accept a change the app does not know how to apply, and offering
  /// the button anyway would mark it accepted while changing nothing.
  static EditSuggestion? fromRow(Map<String, dynamic> row) {
    final kind = SuggestionKind.fromWire(row['kind'] as String?);
    final id = row['id'] as String?;
    final wallId = row['wallId'] as String?;
    final patch = row['patch'];
    if (kind == null || id == null || wallId == null) return null;
    if (patch is! Map) return null;

    final allowed = kSuggestableFields[kind.wire] ?? const [];
    final cleaned = <String, Object?>{
      for (final entry in patch.entries)
        if (allowed.contains(entry.key)) '${entry.key}': entry.value,
    };
    // A patch with nothing applicable left is not a suggestion, it is noise.
    if (cleaned.isEmpty) return null;

    final photoId = row['photoId'] as String?;
    if (kind == SuggestionKind.routeGeometry) {
      // Both halves have to be there for the owner to see anything. A line
      // with no photo cannot be positioned, and a line that will not decode
      // cannot be drawn — either way the row would render as an Apply button
      // over blank space, which is the one thing worse than not showing it.
      if (photoId == null) return null;
      if (GeometryProposal.fromPatch(cleaned) == null) return null;
    }

    return EditSuggestion(
      id: id,
      wallId: wallId,
      wallName: (row['wallName'] as String?)?.trim().isNotEmpty == true
          ? row['wallName'] as String
          : 'Untitled topo',
      kind: kind,
      patch: cleaned,
      createdAt: switch (row['createdAt']) {
        final int v => v,
        final num v => v.toInt(),
        _ => 0,
      },
      isStale: row['isStale'] == true,
      routeId: row['routeId'] as String?,
      routeName: row['routeName'] as String?,
      photoId: photoId,
      authorId: row['authorId'] as String?,
      authorName: (row['authorName'] as String?)?.trim().isNotEmpty == true
          ? row['authorName'] as String
          : null,
      note: (row['note'] as String?)?.trim().isNotEmpty == true
          ? row['note'] as String
          : null,
    );
  }
}
