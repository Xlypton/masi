// Source-level pins on how `database_provider.dart` WIRES the per-operation
// database bound (task #54).
//
// REGRESSION GUARDS, not proof of behaviour. Every assertion here is a string
// match; none of them runs a query. They exist because the two properties
// below are unobservable to `flutter test` for structural reasons:
//
//  * `kIsWeb` is permanently FALSE under `flutter test`, so the only executable
//    assertion available is the negative one
//    (`database_provider_test.dart`'s "the provider is null"). That the gate
//    actually engages on web needs a real browser
//    (`integration_test/web_query_timeout_test.dart`).
//  * `bindQueryTimeout` returning UNCHANGED off web means the whole wiring is
//    inert in every test in this repo. A refactor that dropped
//    `bindQueryTimeout` from `appDatabaseProvider` entirely would leave 1930+
//    tests green and simply un-fix the bug on web.
//
// Follows `connection_seam_source_test.dart`, including its comment-stripping:
// doc comments here legitimately NAME `StorageDurability.unavailable` in prose
// to explain why it must NOT be used, and a raw substring grep would flag that
// as the very thing it is warning against.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Whitespace is collapsed before matching so `dart format`'s line breaking can
/// never make an assertion spuriously fail.
String _normalized(String source) => source.replaceAll(RegExp(r'\s+'), ' ');

/// Keeps only lines containing real Dart code, so the matches below are about
/// USAGE rather than prose.
String _code(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'expected $path to exist');
  return file
      .readAsStringSync()
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  const providerPath = 'lib/core/db/database_provider.dart';

  group('the platform gate', () {
    test('kIsWeb picks the bound, and native gets null', () {
      expect(
        _normalized(_code(providerPath)),
        contains('kIsWeb ? kDatabaseQueryTimeout : null'),
        reason:
            'Both wedge modes are web-only (the OPFS `Atomics.wait`, and '
            "drift's worker-side LazyDatabase). On native a stall is a file "
            'lock or a corrupt database, which a Dart timeout neither fixes '
            'nor diagnoses — so bounding there would buy an executor-identity '
            'change across ~160 call sites on the primary shipped platform '
            'for zero known benefit. `kIsWeb` is the right tool per '
            "CLAUDE.md's convention: a behavioural gate with no `dart:io` "
            'anywhere near it.',
      );
    });
  });

  group('appDatabaseProvider', () {
    test('WRAPS openConnection() in the bound rather than merely mentioning '
        'it next to one', () {
      final code = _normalized(_code(providerPath));
      final boundAt = code.indexOf('bindQueryTimeout(');
      final openAt = code.indexOf('openConnection(');

      expect(boundAt, isNonNegative, reason: 'the bound is gone entirely');
      expect(openAt, isNonNegative);
      expect(
        boundAt,
        lessThan(openAt),
        reason: 'off web `bindQueryTimeout` returns its argument unchanged, so '
            'nothing in this repo\'s 1930+ tests would go red if this call '
            'were dropped — the bug would simply be un-fixed on web, '
            'invisibly',
      );
    });

    test('defers both stall callbacks by a microtask, like onStorageReport', () {
      final code = _normalized(_code(providerPath));
      expect(code, contains('Future<void>.microtask(reporter.onStall)'));
      expect(code, contains('Future<void>.microtask(reporter.onRecovered)'));
      expect(
        code,
        contains('Future<void>.microtask(() => storage.report(verdict))'),
        reason: 'the existing pattern these two match — Riverpod forbids one '
            'provider modifying another during initialization',
      );
    });
  });

  group('the stall verdict', () {
    test('is built with unavailableOver, NEVER plain '
        'StorageDurability.unavailable — the 340ba7b regression', () {
      final code = _normalized(_code(providerPath));

      expect(
        code,
        contains('StorageDurability.unavailableOver('),
        reason:
            'The plain constructor hard-zeroes `measuredBackend` and '
            '`missingFeatures`. Production measures '
            '`opfsLocks / {dedicatedWorkersInSharedWorkers}` seconds before a '
            'stall verdict can exist, and those two fields are the ONLY '
            'field-diagnosable facts this app ever learns about a browser\'s '
            'storage — a real field report came back with no `· missing: …` '
            'segment because an overlay zeroed them. The behaviour is driven '
            "in `database_provider_test.dart`'s StorageStallReporter group; "
            'this pins that production goes through it.',
      );

      // `probeDatabaseUsable` legitimately still uses the plain constructor —
      // it is the one caller with no earlier verdict of its own to overlay —
      // so this is scoped to the stall reporter's body rather than the file.
      final reporterAt = code.indexOf('void onStall() {');
      final reporterEndAt = code.indexOf('void onRecovered() {');
      expect(reporterAt, isNonNegative);
      expect(reporterEndAt, greaterThan(reporterAt));
      expect(
        code.substring(reporterAt, reporterEndAt),
        isNot(contains('StorageDurability.unavailable(')),
      );
    });

    test('is REVERSIBLE, and only reverts what is still in effect', () {
      final code = _normalized(_code(providerPath));
      expect(
        code,
        contains('if (current() != published) return;'),
        reason: 'a verdict reported after ours is a NEWER FACT and must '
            'survive; an unconditional restore would resurrect a stale '
            'verdict over a fresher one. Same discipline as `main.dart`\'s '
            '_reportStalledStorageAtBoot.',
      );
    });
  });
}
