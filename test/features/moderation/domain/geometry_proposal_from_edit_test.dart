
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/domain/geometry_proposal.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// Pins `GeometryProposal.fromEdit` (`geometry_proposal.dart`) -- the
/// non-owner half of `ROUTE_EDITING_PLAN.md` §3.2, where a visitor's canvas
/// edit of someone else's committed route becomes a proposal instead of a
/// write.
///
/// The whole point of this file is the null-versus-empty rule for [symbols]:
/// null means "this proposal says nothing about markers, leave the owner's
/// alone", `[]` means "I deliberately removed every marker". Collapsing
/// those two in either direction is silent data loss -- see the class doc on
/// `GeometryProposal.symbols` and on `fromEdit` itself.
void main() {
  const p0 = Offset(0.1, 0.1);
  const p1 = Offset(0.2, 0.2);
  const p2 = Offset(0.3, 0.3);

  const bolt = TopoSymbol(type: SymbolType.bolt, position: Offset(0.4, 0.4));
  const anchor = TopoSymbol(
    type: SymbolType.anchor,
    position: Offset(0.5, 0.5),
  );
  const movedBolt = TopoSymbol(
    type: SymbolType.bolt,
    position: Offset(0.6, 0.6),
  );

  group('the null-vs-empty rule for symbols', () {
    test(
      'markers untouched (non-empty, equal lists) -> symbols is null, and '
      "toPatch() carries no 'symbols' key at all",
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1, p2],
          symbols: const [bolt, anchor],
          originalSymbols: const [bolt, anchor],
        );

        expect(
          proposal.symbols,
          isNull,
          reason: 'nothing changed about the markers, so the proposal must '
              'say nothing about them',
        );
        final patch = proposal.toPatch();
        expect(
          patch.containsKey('symbols'),
          isFalse,
          reason: "the key's mere presence (even as null) would be read as "
              'a statement about markers by fromPatch',
        );
      },
    );

    test(
      'markers untouched (both empty) -> symbols is still null, not []',
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1],
          symbols: const [],
          originalSymbols: const [],
        );

        expect(
          proposal.symbols,
          isNull,
          reason: 'a route with no markers before and after was never '
              'touched -- the empty-vs-empty case must not be read as a '
              'deliberate clear',
        );
        expect(proposal.toPatch().containsKey('symbols'), isFalse);
      },
    );

    test('a marker moved -> symbols is the new list', () {
      final proposal = GeometryProposal.fromEdit(
        points: [p0, p1],
        symbols: const [movedBolt, anchor],
        originalSymbols: const [bolt, anchor],
      );

      expect(proposal.symbols, [movedBolt, anchor]);
      expect(proposal.toPatch()['symbols'], isNotNull);
    });

    test(
      'a marker removed from several -> symbols is the new (shorter) list',
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1],
          symbols: const [anchor],
          originalSymbols: const [bolt, anchor],
        );

        expect(proposal.symbols, [anchor]);
      },
    );

    test(
      'ALL markers removed when there were some -> symbols is [] (an empty '
      'list, NOT null), and toPatch() DOES carry a symbols key with an '
      'empty array',
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1],
          symbols: const [],
          originalSymbols: const [bolt, anchor],
        );

        expect(
          proposal.symbols,
          isNotNull,
          reason: 'this is a deliberate "I removed them", distinct from '
              '"I said nothing about them"',
        );
        expect(proposal.symbols, isEmpty);

        final patch = proposal.toPatch();
        expect(
          patch.containsKey('symbols'),
          isTrue,
          reason: 'the removal must be expressed on the wire, or accepting '
              "this proposal would leave the owner's markers untouched "
              'instead of clearing them',
        );
        expect(patch['symbols'], isEmpty);
      },
    );
  });

  group('returned lists are copies', () {
    test('mutating the points list passed in does not change the proposal', () {
      final points = [p0, p1, p2];
      final proposal = GeometryProposal.fromEdit(
        points: points,
        symbols: const [],
        originalSymbols: const [],
      );

      points.add(const Offset(0.9, 0.9));
      points[0] = const Offset(-1, -1);

      expect(proposal.points, [p0, p1, p2]);
    });

    test(
      'mutating the symbols list passed in does not change the proposal '
      '(changed-markers case, where symbols is non-null)',
      () {
        final symbols = [movedBolt, anchor];
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1],
          symbols: symbols,
          originalSymbols: const [bolt, anchor],
        );

        symbols.add(bolt);
        symbols.clear();

        expect(proposal.symbols, [movedBolt, anchor]);
      },
    );
  });

  group('isWithinLimits / isSendable at the boundaries', () {
    test('exactly kMaxProposedPoints points is within limits', () {
      final points = List.generate(
        kMaxProposedPoints,
        (i) => Offset(i / (kMaxProposedPoints + 1), 0.5),
      );
      final proposal = GeometryProposal.fromEdit(
        points: points,
        symbols: const [],
        originalSymbols: const [],
      );

      expect(proposal.points, hasLength(kMaxProposedPoints));
      expect(proposal.isWithinLimits, isTrue);
      expect(proposal.isSendable, isTrue);
    });

    test('kMaxProposedPoints + 1 points is NOT within limits', () {
      final points = List.generate(
        kMaxProposedPoints + 1,
        (i) => Offset(i / (kMaxProposedPoints + 2), 0.5),
      );
      final proposal = GeometryProposal.fromEdit(
        points: points,
        symbols: const [],
        originalSymbols: const [],
      );

      expect(proposal.isWithinLimits, isFalse);
      expect(proposal.isSendable, isFalse);
    });

    test('exactly kMaxProposedSymbols markers is within limits', () {
      final symbols = List.generate(
        kMaxProposedSymbols,
        (i) => TopoSymbol(
          type: SymbolType.bolt,
          position: Offset(i / (kMaxProposedSymbols + 1), 0.5),
        ),
      );
      final proposal = GeometryProposal.fromEdit(
        points: [p0, p1],
        symbols: symbols,
        // A different original so the changed-markers branch is taken and
        // symbols is non-null (the case isWithinLimits actually measures).
        originalSymbols: const [],
      );

      expect(proposal.symbols, hasLength(kMaxProposedSymbols));
      expect(proposal.isWithinLimits, isTrue);
    });

    test('kMaxProposedSymbols + 1 markers is NOT within limits', () {
      final symbols = List.generate(
        kMaxProposedSymbols + 1,
        (i) => TopoSymbol(
          type: SymbolType.bolt,
          position: Offset(i / (kMaxProposedSymbols + 2), 0.5),
        ),
      );
      final proposal = GeometryProposal.fromEdit(
        points: [p0, p1],
        symbols: symbols,
        originalSymbols: const [],
      );

      expect(proposal.isWithinLimits, isFalse);
      expect(proposal.isSendable, isFalse);
    });

    test('a 1-point line is not sendable, even within the size limits', () {
      final proposal = GeometryProposal.fromEdit(
        points: [p0],
        symbols: const [],
        originalSymbols: const [],
      );

      expect(proposal.isDrawable, isFalse);
      expect(
        proposal.isWithinLimits,
        isTrue,
        reason: 'one point is well within the size caps -- it fails on '
            'drawability, not size',
      );
      expect(proposal.isSendable, isFalse);
    });
  });

  group('round trip through toPatch() / fromPatch()', () {
    test(
      'preserves points and the null-vs-empty symbols distinction (null '
      'case)',
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1, p2],
          symbols: const [bolt],
          originalSymbols: const [bolt],
        );
        expect(proposal.symbols, isNull, reason: 'precondition');

        final roundTripped = GeometryProposal.fromPatch(proposal.toPatch());

        expect(roundTripped, isNotNull);
        expect(roundTripped!.points, proposal.points);
        expect(
          roundTripped.symbols,
          isNull,
          reason: 'an absent key must decode back to null, not []',
        );
      },
    );

    test(
      'preserves points and the null-vs-empty symbols distinction (empty '
      'case)',
      () {
        final proposal = GeometryProposal.fromEdit(
          points: [p0, p1, p2],
          symbols: const [],
          originalSymbols: const [bolt, anchor],
        );
        expect(proposal.symbols, isEmpty, reason: 'precondition');
        expect(proposal.symbols, isNotNull, reason: 'precondition');

        final roundTripped = GeometryProposal.fromPatch(proposal.toPatch());

        expect(roundTripped, isNotNull);
        expect(roundTripped!.points, proposal.points);
        expect(
          roundTripped.symbols,
          isNotNull,
          reason: 'a deliberate clear must decode back to [], not null',
        );
        expect(roundTripped.symbols, isEmpty);
      },
    );

    test('preserves points and a non-empty changed symbols list', () {
      final proposal = GeometryProposal.fromEdit(
        points: [p0, p1],
        symbols: const [movedBolt, anchor],
        originalSymbols: const [bolt, anchor],
      );

      final roundTripped = GeometryProposal.fromPatch(proposal.toPatch());

      expect(roundTripped, isNotNull);
      expect(roundTripped!.points, proposal.points);
      expect(roundTripped.symbols, [movedBolt, anchor]);
    });
  });
}
