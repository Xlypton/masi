// The submit half of `ROUTE_EDITING_PLAN.md` §3.2: a visitor edits somebody
// else's route, the edit is kept in memory and never written, and this bar is
// the only way it can go anywhere.
//
// The properties worth pinning, roughly in order of how expensive getting them
// wrong would be:
//
//   * **Send actually files a suggestion**, with the edited geometry, the
//     route's DATABASE id (not its in-memory id — those are different numbers
//     and the owner's inbox resolves by the former), and the photo the points
//     are percentages of.
//   * **A send that fails keeps the edit.** There is no outbox (decision D-4),
//     so a swallowed failure means somebody believes they have offered a
//     correction that never left the device.
//   * **The bar says "not saved" while the edit is visible.** The edit looks
//     exactly like an owner's would, so without that sentence the reasonable
//     reading is that it saved.
//   * Discard, and the post-send restore, put the owner's geometry back —
//     nothing was ever written, so that is a complete undo.
//
// Ownership itself is driven straight through `DrawController` rather than
// through a foreign `ownerId`: which wall is foreign is
// `wall_route_edit_permission_test.dart`'s subject, and threading it through
// here would make every assertion below depend on that answer resolving first.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

/// Records what was filed instead of talking to Supabase. `suggest` is the
/// only method these tests reach; the rest of the seam is deliberately left
/// unimplemented so a test that starts using one fails loudly rather than
/// silently asserting against a stub.
class _RecordingSuggestionsRemote implements SuggestionsRemote {
  final List<Map<String, Object?>> filed = [];

  /// When non-null, every [suggest] throws this instead of recording.
  Object? failWith;

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) async {
    final error = failWith;
    if (error != null) throw error;
    filed.add({
      'wallId': wallId,
      'kind': kind,
      'patch': patch,
      'note': note,
      'routeId': routeId,
      'photoId': photoId,
    });
    return 'suggestion-${filed.length}';
  }

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) =>
      throw UnimplementedError();

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) => throw UnimplementedError();
}

typedef _Seeded = ({
  ProviderContainer container,
  String wallId,
  String photoId,
  _RecordingSuggestionsRemote remote,
  AppDatabase db,
});

Future<_Seeded> _seedWall(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final remote = _RecordingSuggestionsRemote();
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      suggestionsRemoteProvider.overrideWithValue(remote),
    ],
  );
  addTearDown(container.dispose);

  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/topo-canvas-proposal-bar-test-photo.jpg'),
      1000,
      2000,
    );
  });

  // A route already on disk, so it has a real database id for the suggestion
  // to target — the whole point of the routeId assertion below.
  await RouteRepository(db, nowMs: () => 1000).upsertRoute(
    wall.id,
    photoId,
    const TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.2, 0.2), Offset(0.5, 0.5), Offset(0.8, 0.8)],
      symbols: [
        TopoSymbol(type: SymbolType.bolt, position: Offset(0.3, 0.3)),
      ],
    ),
  );

  return (
    container: container,
    wallId: wall.id,
    photoId: photoId,
    remote: remote,
    db: db,
  );
}

Future<void> _pump(WidgetTester tester, _Seeded seeded) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: seeded.container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: TopoCanvasScreen(
          wallId: seeded.wallId,
          debugInitialImageSize: const Size(1000, 2000),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

DrawController _notifier(_Seeded s) =>
    s.container.read(drawControllerProvider(s.wallId).notifier);

DrawState _state(_Seeded s) =>
    s.container.read(drawControllerProvider(s.wallId));

/// Opens the note dialog.
///
/// Fixed pumps rather than `pumpAndSettle`, and that is not a style choice:
/// the dialog contains a `TextField`, whose caret blinks forever, so
/// `pumpAndSettle` has no quiet frame to settle on and times out. Every
/// interaction with this dialog has to advance time explicitly.
Future<void> _openNoteDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('topo-proposal-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Confirms the note dialog and lets the send, the dialog's dismissal and the
/// resulting SnackBar all land.
Future<void> _confirmNote(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('topo-proposal-note-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Puts the controller in proposal-only mode and moves one point of the
/// loaded route, exactly as a non-owner's drag would.
Future<void> _editAsVisitor(WidgetTester tester, _Seeded seeded) async {
  final notifier = _notifier(seeded);
  notifier.setProposalOnlyGeometryEdits(true);
  notifier.setMode(DrawMode.draw);
  notifier.moveRoutePoint(1, 1, const Offset(0.6, 0.4));
  await notifier.endRouteGeometryEdit(1);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the bar appears once there is something to suggest, and says the edit '
    'is NOT saved — it looks identical to an owner\'s, so silence would read '
    'as "saved"',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      expect(find.byKey(const Key('topo-proposal-bar')), findsNothing);

      await _editAsVisitor(tester, seeded);

      expect(find.byKey(const Key('topo-proposal-bar')), findsOneWidget);
      expect(find.textContaining('not saved'), findsOneWidget);
      expect(
        seeded.remote.filed,
        isEmpty,
        reason: 'nothing is filed until the visitor asks for it',
      );
    },
  );

  testWidgets(
    'Send files one routeGeometry suggestion carrying the edited points, the '
    "route's DATABASE id and the photo the percentages belong to",
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      final dbIds = await RouteRepository(
        seeded.db,
        nowMs: () => 1000,
      ).routeDbIdsByNumber(seeded.wallId, seeded.photoId);

      await _editAsVisitor(tester, seeded);
      await _openNoteDialog(tester);
      await _confirmNote(tester);

      expect(seeded.remote.filed, hasLength(1));
      final filed = seeded.remote.filed.single;
      expect(filed['kind'], SuggestionKind.routeGeometry);
      expect(filed['wallId'], seeded.wallId);
      expect(filed['photoId'], seeded.photoId);
      expect(
        filed['routeId'],
        dbIds[1],
        reason:
            "the owner's inbox resolves by database id, not by the canvas' "
            'in-memory route id',
      );

      final patch = filed['patch']! as Map<String, Object?>;
      final points = patch['points']! as List;
      expect(points, hasLength(3));
      expect((points[1] as Map)['x'], closeTo(0.6, 0.0001));
      expect((points[1] as Map)['y'], closeTo(0.4, 0.0001));
      expect(
        patch.containsKey('symbols'),
        isFalse,
        reason:
            'the markers were untouched, so the proposal must say NOTHING '
            "about them — sending [] would wipe the owner's bolt when they "
            'accepted a line correction',
      );
    },
  );

  testWidgets(
    'a successful send restores the owner\'s geometry and clears the bar — '
    'the suggestion lives on the server now, and a line that exists nowhere '
    'else would read as accepted',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      await _editAsVisitor(tester, seeded);

      await _openNoteDialog(tester);
      await _confirmNote(tester);

      expect(
        _state(seeded).routes.single.points[1],
        const Offset(0.5, 0.5),
      );
      expect(_state(seeded).pendingProposalBaselines, isEmpty);
      expect(find.byKey(const Key('topo-proposal-bar')), findsNothing);
      expect(find.byKey(const Key('topo-proposal-sent')), findsOneWidget);
    },
  );

  testWidgets(
    'a send that FAILS keeps the edit and says so — with no outbox, a '
    'swallowed failure means believing you offered a correction that never '
    'left the device',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      await _editAsVisitor(tester, seeded);
      seeded.remote.failWith = Exception('network down');

      await _openNoteDialog(tester);
      await _confirmNote(tester);

      expect(
        _state(seeded).routes.single.points[1].dx,
        closeTo(0.6, 0.0001),
        reason: 'the edit must survive so it can be retried',
      );
      expect(_state(seeded).pendingProposalBaselines, hasLength(1));
      expect(find.byKey(const Key('topo-proposal-bar')), findsOneWidget);
      expect(find.textContaining('still here'), findsOneWidget);
    },
  );

  testWidgets(
    'Discard puts the owner\'s geometry back — nothing was ever written, so '
    'that is the whole undo, with no reload and no network',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      await _editAsVisitor(tester, seeded);

      await tester.tap(find.byKey(const Key('topo-proposal-discard')));
      await tester.pumpAndSettle();

      expect(_state(seeded).routes.single.points, const [
        Offset(0.2, 0.2),
        Offset(0.5, 0.5),
        Offset(0.8, 0.8),
      ]);
      expect(_state(seeded).pendingProposalBaselines, isEmpty);
      expect(find.byKey(const Key('topo-proposal-bar')), findsNothing);
      expect(seeded.remote.filed, isEmpty);
    },
  );

  testWidgets(
    'backing out of the note keeps everything — dismissing a dialog must not '
    'also throw away the line that was drawn',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      await _editAsVisitor(tester, seeded);

      await _openNoteDialog(tester);
      // Tap outside the dialog to dismiss it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(seeded.remote.filed, isEmpty);
      expect(_state(seeded).pendingProposalBaselines, hasLength(1));
      expect(find.byKey(const Key('topo-proposal-bar')), findsOneWidget);
    },
  );

  testWidgets(
    'an edit that erases every marker DOES say so — an empty list is a '
    'deliberate removal, and collapsing it to null would drop it silently',
    (tester) async {
      final seeded = await _seedWall(tester);
      await _pump(tester, seeded);
      final notifier = _notifier(seeded);
      notifier.setProposalOnlyGeometryEdits(true);
      notifier.setMode(DrawMode.draw);
      notifier.removeRouteSymbol(1, 0);
      await notifier.endRouteGeometryEdit(1);
      await tester.pumpAndSettle();

      await _openNoteDialog(tester);
      await _confirmNote(tester);

      final patch = seeded.remote.filed.single['patch']! as Map<String, Object?>;
      expect(patch.containsKey('symbols'), isTrue);
      expect(patch['symbols'], isEmpty);
    },
  );
}
