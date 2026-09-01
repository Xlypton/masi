/// One thing that happened to you, or to something you made.
///
/// The domain half of `public.notifications` and its local mirror
/// [NotificationRows]. Everything here is parsing and phrasing; nothing here
/// does I/O, so the whole of it is testable without a database or a network.
library;

/// What happened, as this build understands it.
///
/// [unknown] is not a failure case and is not an error — it is the
/// forward-compatibility contract stated in `NotificationRows`' doc comment.
/// The server stores `kind` as raw text precisely so a new kind can ship
/// without a coordinated client release, which is only true if an OLD client
/// meeting a NEW kind renders something rather than throwing. A notification
/// centre that crashes the moment the server learns a new verb would make
/// every future addition a breaking change.
enum NotificationKind {
  /// Somebody commented on your topo, or on your shared ascent.
  comment,

  /// Somebody tagged you in a comment. Distinct from [comment] because being
  /// named is a different, more direct fact than something happening near you
  /// — and the server never sends both for one comment.
  mention,

  /// Somebody liked your topo or your shared ascent.
  like,

  /// Somebody proposed an edit to your topo.
  suggestion,

  /// A kind this build has never heard of. Renders as a plain entry that still
  /// says who did it and when, because those two fields are common to every
  /// kind and are enough for a person to decide whether to go and look.
  unknown;

  /// The server's wire value, or [unknown] for anything unrecognised —
  /// including null, an empty string, or a value from a newer server.
  static NotificationKind fromWire(String? wire) => switch (wire) {
    'comment' => NotificationKind.comment,
    'mention' => NotificationKind.mention,
    'like' => NotificationKind.like,
    'suggestion' => NotificationKind.suggestion,
    _ => NotificationKind.unknown,
  };
}

/// A parsed notification, ready to render.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    this.actorId,
    this.actorName,
    this.wallId,
    this.ascentId,
    this.commentId,
    this.preview,
    required this.createdAt,
    this.readAt,
  });

  /// Builds one from a raw `my_notifications` row (or a mirrored local row),
  /// or null if it cannot be rendered at all.
  ///
  /// The bar for "cannot be rendered" is deliberately low: an id and a
  /// timestamp. Everything else has a sensible absence — an unknown kind
  /// renders generically, a missing actor renders as "Someone", a missing
  /// target simply is not tappable. Dropping more than this would mean an
  /// inbox that silently loses entries whenever the server grows a field,
  /// which is the failure mode the raw-`kind` design exists to avoid.
  ///
  /// The two REQUIRED fields are the two the list itself is built from: a row
  /// with no id cannot be marked read or de-duplicated, and one with no
  /// timestamp has no place in a newest-first list.
  static AppNotification? fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.isEmpty) return null;
    final createdAt = _asInt(row['createdAt']);
    if (createdAt == null) return null;

    return AppNotification(
      id: id,
      kind: NotificationKind.fromWire(_text(row['kind'])),
      actorId: _text(row['actorId']),
      actorName: _text(row['actorName']),
      wallId: _text(row['wallId']),
      ascentId: _text(row['ascentId']),
      commentId: _text(row['commentId']),
      preview: _text(row['preview']),
      createdAt: createdAt,
      readAt: _asInt(row['readAt']),
    );
  }

  final String id;
  final NotificationKind kind;

  /// Who did it. Never rendered directly — see [actorLabel].
  final String? actorId;

  /// The actor's display name as the server resolved it — `my_notifications`
  /// joins `profiles` because a notification arrives precisely BECAUSE
  /// somebody acted on your work, and that somebody is often a person whose
  /// profile this device has never pulled.
  ///
  /// **Null for anything read back from the local mirror.** `NotificationRows`
  /// has no column for it (and the schema is fixed), so this survives only
  /// within the session that fetched it. That is why it is the SECOND choice
  /// in [labelWith] rather than the first: the durable answer is the local
  /// `profiles` mirror, which every screen in the app already resolves names
  /// through, and this is the fallback for an actor that mirror has never
  /// heard of.
  final String? actorName;

  final String? wallId;
  final String? ascentId;
  final String? commentId;

  /// A short server-rendered summary: the comment's first line, or the topo's
  /// name. Never required.
  final String? preview;

  final int createdAt;

  /// When it was read, or null while unread.
  final int? readAt;

  bool get isUnread => readAt == null;

  /// Where tapping this should go, or null when there is nothing to open.
  ///
  /// The ascent wins over the wall when both are set, which is the normal
  /// shape for anything about a shared ascent: the server carries the wall
  /// too, but only so the entry can SAY which topo — the thing the person
  /// wants to look at is the ascent they were commented on.
  String? get route {
    if (ascentId != null) return '/community/ascent/$ascentId';
    if (wallId != null) return '/community/topo/$wallId';
    return null;
  }

  /// Who did it, as a person is named on screen.
  ///
  /// [resolved] is the name from the local `profiles` mirror — what
  /// `profileDisplayNameProvider` yields — and wins, because a display name is
  /// editable (#18) and the mirror is the live copy while [actorName] is
  /// whatever the server said at fetch time.
  ///
  /// Falls back to "Someone" and NEVER to [actorId]. A raw uid on screen is
  /// not a degraded name, it is an internal identifier leaking into a
  /// sentence — and "Someone commented on your topo" is a true, complete
  /// sentence, while "b3f1c2a8-… commented on your topo" is neither.
  String labelWith(String? resolved) {
    for (final candidate in [resolved, actorName]) {
      final name = candidate?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return 'Someone';
  }

  /// [labelWith] with nothing resolved — the honest answer when the actor is
  /// a stranger this device holds no profile for.
  String get actorLabel => labelWith(null);

  /// The whole entry as one sentence, written the way a person would say it.
  ///
  /// Assembled here rather than in the widget so the row, an accessibility
  /// label and any future push payload cannot describe the same event
  /// differently — and so the phrasing is unit-testable without pumping a
  /// widget tree.
  ///
  /// Note what changes with the target and what does not: "your topo" and
  /// "your ascent" are different enough to matter (one is a place, the other
  /// is a climb somebody did), so they are not collapsed into "your post".
  String sentenceWith(String? resolvedActorName) {
    final who = labelWith(resolvedActorName);
    final target = ascentId != null ? 'your ascent' : 'your topo';
    return switch (kind) {
      NotificationKind.comment => '$who commented on $target',
      NotificationKind.mention => '$who mentioned you in a comment',
      NotificationKind.like => '$who liked $target',
      NotificationKind.suggestion => '$who suggested an edit to your topo',
      // Deliberately says nothing about WHAT happened, because this build does
      // not know. It is still a complete sentence, and the entry stays
      // tappable, so the user can go and see for themselves — which is a
      // better outcome than hiding the row and better than a crash.
      NotificationKind.unknown => '$who did something on $target',
    };
  }

  /// [sentenceWith] with nothing resolved.
  String get sentence => sentenceWith(null);

  /// The second line: the comment excerpt, or the topo name, or nothing.
  ///
  /// Suppressed when it would merely repeat [sentence] — a `like` row whose
  /// preview is the topo name already reads as "Kata liked your topo", and
  /// stacking the name under it adds a line without adding a fact. Kept for
  /// comments, where the excerpt is the entire reason to look.
  String? get detail {
    final text = preview?.trim();
    if (text == null || text.isEmpty) return null;
    return switch (kind) {
      NotificationKind.comment || NotificationKind.mention => text,
      _ => null,
    };
  }

  static String? _text(Object? value) => switch (value) {
    final String s when s.trim().isNotEmpty => s,
    _ => null,
  };

  /// PostgREST hands `bigint` back as an `int`, but a JSON round trip through
  /// a fake, a future server change or the local mirror could produce a `num`
  /// or a `String`. Coerced rather than cast, so one odd row cannot throw
  /// mid-import.
  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}

/// "just now" / "4m" / "3h" / "6d" — the age shown beside an entry.
///
/// A free function rather than a getter on [AppNotification] because it needs
/// a clock, and a domain object that reads `DateTime.now()` internally is one
/// that cannot be tested at a fixed instant.
///
/// Coarse on purpose, and capped at days: an inbox is scanned, not read, and
/// "23h" and "1d" are the same fact to somebody deciding whether to tap.
String notificationAge(int createdAtMs, {required DateTime now}) {
  final age = now.difference(DateTime.fromMillisecondsSinceEpoch(createdAtMs));
  if (age.inDays >= 1) return '${age.inDays}d';
  if (age.inHours >= 1) return '${age.inHours}h';
  if (age.inMinutes >= 1) return '${age.inMinutes}m';
  return 'just now';
}

/// How old an entry is, coarsely — the inbox's section headings.
///
/// Three buckets and not five: a notification centre is scanned top-down and
/// the only question a heading has to answer is "is this still current?".
/// Finer buckets ("Yesterday", "Last month") would split a short list into
/// sections of one, which reads as clutter rather than as structure.
enum NotificationAgeBucket {
  /// The same CALENDAR day as now — not "within 24 hours". Something that
  /// happened at 23:50 yesterday is not "today" to the person reading this
  /// at 08:00, whatever the elapsed hours say.
  today,

  /// Within the last seven days, and not [today].
  thisWeek,

  /// Everything else.
  earlier;

  /// The section heading, as rendered.
  String get label => switch (this) {
    NotificationAgeBucket.today => 'Today',
    NotificationAgeBucket.thisWeek => 'This week',
    NotificationAgeBucket.earlier => 'Earlier',
  };
}

/// Which section [createdAtMs] belongs to.
///
/// Takes [now] rather than reading the clock, for the same reason
/// [notificationAge] does: a bucket boundary that cannot be pinned to a fixed
/// instant cannot be tested at one.
NotificationAgeBucket notificationBucket(int createdAtMs, {required DateTime now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  final startOfToday = DateTime(now.year, now.month, now.day);
  if (!at.isBefore(startOfToday)) return NotificationAgeBucket.today;
  if (!at.isBefore(startOfToday.subtract(const Duration(days: 6)))) {
    return NotificationAgeBucket.thisWeek;
  }
  return NotificationAgeBucket.earlier;
}

/// One rendered section of the inbox: a heading and the entries under it.
typedef NotificationSection = ({
  NotificationAgeBucket bucket,
  List<AppNotification> items,
});

/// Splits a newest-first [list] into its age sections, preserving order and
/// dropping empty sections.
///
/// A pure function over the list the screen already has, rather than a
/// second query: the mirror is the only source, and grouping in SQL would put
/// the section boundaries somewhere no test could reach without a database.
///
/// Assumes [list] is already newest-first (which is what
/// `NotificationsRepository.watchAll` guarantees) and does NOT re-sort — a
/// list that arrived out of order would produce interleaved sections here,
/// which is a visible, debuggable wrong rather than a silently reordered
/// inbox.
List<NotificationSection> groupNotificationsByAge(
  List<AppNotification> list, {
  required DateTime now,
}) {
  final sections = <NotificationSection>[];
  for (final n in list) {
    final bucket = notificationBucket(n.createdAt, now: now);
    if (sections.isNotEmpty && sections.last.bucket == bucket) {
      sections.last.items.add(n);
    } else {
      sections.add((bucket: bucket, items: [n]));
    }
  }
  return sections;
}

/// The glyph that says WHAT happened, from `assets/icons/masi/`.
///
/// Every kind gets its own, because the whole point of a badge next to the
/// actor is that the row is legible before it is read. [NotificationKind.
/// unknown] falls back to `flash` — the same "something happened" glyph the
/// bell itself uses, which is exactly as much as an old client meeting a new
/// verb can honestly claim.
String notificationKindGlyph(NotificationKind kind) => switch (kind) {
  NotificationKind.comment => 'comment',
  NotificationKind.mention => 'person',
  NotificationKind.like => 'heart_fill',
  NotificationKind.suggestion => 'edit',
  NotificationKind.unknown => 'flash',
};
