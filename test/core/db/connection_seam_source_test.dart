import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `connection_web.dart` is the single most safety-critical file in the web
/// build — it is where L1 (a silent `inMemory` drift backend that loses the
/// whole library on reload) is either caught or missed — and it is the ONE
/// file `flutter test` can never execute: it imports
/// `package:drift/wasm.dart`, which imports `dart:js_interop`, so the Dart VM
/// cannot compile it at all.
///
/// Coverage is therefore split three ways:
///  - `flutter analyze` type-checks it, including the exhaustiveness of its
///    two enum switches (a drift upgrade adding a storage implementation is
///    an analyzer error);
///  - `integration_test/web_storage_backend_test.dart` exercises it for real
///    in a browser;
///  - THIS test pins the properties neither of those can assert: that the
///    verdict is surfaced rather than discarded, that the log is not gated
///    behind `kDebugMode`, that `moveExistingIndexedDbToOpfs` is NOT passed
///    (drift 2.34.2's IndexedDB->OPFS move is neither locked nor crash-safe —
///    see the assertion's own reason), and that the drift->masi enum mapping
///    is value-for-value correct (analyze proves the switch is TOTAL, not
///    that it maps `inMemory` to `inMemory`).
///
/// Whitespace is collapsed before matching so `dart format`'s line breaking
/// can never make an assertion spuriously fail.
String _normalized(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'expected $path to exist');
  return file.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
}

/// Strips whole-line `//`/`///` comments, keeping only lines that contain
/// real Dart code, so the `kDebugMode` guards below match *usage* — an
/// `if (kDebugMode)`, a `kDebugMode ?`/`&&` expression, an import-and-use —
/// rather than prose. Doc comments legitimately NAME `kDebugMode` to explain
/// that a log is deliberately not gated behind it (see
/// `connection_web.dart`, `storage_durability.dart`,
/// `storage_persistence_providers.dart`); a bare substring grep over the raw
/// file flags those as false positives. Same fix as the `dart:io` gate in
/// `tool/build_web.sh`, which anchors on import/export directives instead of
/// grepping the raw token — this is that gate's comment-stripping analogue
/// for an identifier rather than a directive.
String _stripCommentLines(String source) {
  return source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  const webPath = 'lib/core/db/connection/connection_web.dart';
  const nativePath = 'lib/core/db/connection/connection_native.dart';

  group('connection_web.dart', () {
    test("surfaces drift's verdict instead of discarding it", () {
      final source = _normalized(webPath);
      expect(source, contains('onStorageReport?.call('));
      expect(source, contains('_backendOf(result.chosenImplementation)'));
      expect(source, contains('result.missingFeatures'));
    });

    test('logs OUTSIDE kDebugMode — no kDebugMode gate anywhere', () {
      final code = _stripCommentLines(File(webPath).readAsStringSync());
      expect(
        code,
        isNot(contains('kDebugMode')),
        reason:
            'the pre-fix code hid the storage verdict behind '
            '`if (kDebugMode)`, which is precisely why total data loss was '
            'invisible in the release web build (the doc comment above '
            '`openConnection` legitimately NAMES `kDebugMode` in prose to '
            'explain that history — this checks code, not comments)',
      );
    });

    test('returns DatabaseConnection.delayed(resolvedExecutor), never a bare '
        'LazyDatabase — a bare one discards drift\'s BroadcastStreamQueryStore '
        'and silently breaks cross-tab watch()', () {
      final source = _normalized(webPath);
      expect(source, contains('DatabaseConnection.delayed('));
      expect(source, contains('return result.resolvedExecutor;'));
    });

    test('a throwing WasmDatabase.open REPORTS before it rethrows — reporting '
        'after the rethrow would be dead code, leaving the verdict stuck at '
        'probing (which the interlock reads as allow-creation)', () {
      final source = _normalized(webPath);
      final reportIndex = source.indexOf(
        'onStorageReport?.call(StorageDurability.unavailable(',
      );
      final rethrowIndex = source.indexOf('rethrow;');
      expect(
        reportIndex,
        greaterThan(-1),
        reason: 'expected the catch to report an unavailable verdict',
      );
      expect(rethrowIndex, greaterThan(-1), reason: 'expected a rethrow');
      expect(
        reportIndex,
        lessThan(rethrowIndex),
        reason: 'the unavailable report must precede the rethrow',
      );
    });

    test('BOUNDS the open — an unbounded WasmDatabase.open leaves the verdict '
        'at `probing` forever, which the create-topo interlock reads as '
        'allow-creation', () {
      // Source-level because `connection_web.dart` imports
      // `package:drift/wasm.dart` -> `dart:js_interop` and cannot be loaded by
      // the Dart VM at all. The bound's BEHAVIOUR is driven for real in
      // `test/core/db/storage_durability_test.dart`'s `boundStorageOpen` group;
      // what can only be checked here is that production actually goes through
      // it. `.timeout(` inline would satisfy neither test, hence the named
      // helper.
      final code = _stripCommentLines(File(webPath).readAsStringSync());
      final boundAt = code.indexOf('boundStorageOpen(');
      final openAt = code.indexOf('WasmDatabase.open(');

      expect(
        boundAt,
        isNonNegative,
        reason: 'drift 2.34.2 has four awaits on this path that can never '
            'complete, and the sqlite3 OPFS VFS blocks on '
            '`Atomics.wait(..., -1)` with no timeout — nothing else stops a '
            'wedged worker hanging the open for the lifetime of the page',
      );
      expect(openAt, isNonNegative, reason: 'expected a WasmDatabase.open call');
      expect(
        boundAt,
        lessThan(openAt),
        reason: 'the open must be WRAPPED by the bound, not merely mentioned '
            'next to it',
      );
    });

    test('does NOT pass moveExistingIndexedDbToOpfs — drift 2.34.2 cannot '
        'perform that move safely', () {
      // Comment-stripped: the doc block above the `WasmDatabase.open` call
      // legitimately NAMES the flag in prose to record why it is off, exactly
      // like the `kDebugMode` guard above. This checks the argument list.
      final code = _stripCommentLines(File(webPath).readAsStringSync());
      expect(
        code,
        isNot(contains('moveExistingIndexedDbToOpfs')),
        reason:
            'This pin was previously INVERTED — it required '
            '`moveExistingIndexedDbToOpfs: true` to mitigate L8 lock-in, on '
            "the belief that drift's move was atomic. It is not, in 2.34.2: "
            '`moveIndexedDBDatabaseToOpfs` '
            '(drift/src/web/wasm_setup/indexeddb_to_opfs.dart:13-79) takes no '
            'Web Lock and creates the OPFS `database` file handle (:42) '
            'before writing any bytes, while `opfsDatabases()` '
            '(wasm_setup/shared.dart:204-230) treats the mere existence of '
            'that handle as "a database lives here". A tab killed inside that '
            'window therefore leaves a zero-byte OPFS database that '
            '`_selectExistingDatabase` (wasm.dart:227-252) may pick over the '
            'intact IndexedDB one, with no recovery and a fully DURABLE '
            'verdict reported. That fires once per existing install on the '
            'first load after deploy — i.e. only for users who already have '
            'topos. L8 lock-in (staying on `sharedIndexedDb`, which persists '
            'fine) is the accepted cost; losing a library is not. See the '
            'comment block in connection_web.dart for the full trace.',
      );
    });

    test('maps every drift storage implementation to the right backend', () {
      final source = _normalized(webPath);
      for (final name in const [
        'opfsShared',
        'opfsLocks',
        'sharedIndexedDb',
        'unsafeIndexedDb',
        'inMemory',
      ]) {
        expect(
          source,
          contains('WasmStorageImplementation.$name => StorageBackend.$name,'),
          reason:
              "mapping drift's $name onto anything but "
              'StorageBackend.$name would silently mis-report durability',
        );
      }
    });

    test('maps every drift missing-browser-feature', () {
      final source = _normalized(webPath);
      for (final name in const [
        'sharedWorkers',
        'dedicatedWorkers',
        'dedicatedWorkersInSharedWorkers',
        'fileSystemAccess',
        'indexedDb',
        'sharedArrayBuffers',
        'workerError',
      ]) {
        expect(
          source,
          contains(
            'MissingBrowserFeature.$name => StorageMissingFeature.$name,',
          ),
        );
      }
    });
  });

  group('lib/ has no kDebugMode-gated diagnostics left', () {
    test('zero kDebugMode occurrences under lib/ (code, not comments)', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        final code = _stripCommentLines(entity.readAsStringSync());
        if (code.contains('kDebugMode')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'lib/ had exactly ONE kDebugMode before this work — the '
            'swallowed drift storage verdict (L1). Any new one is a '
            'diagnostic that will be invisible in the release web build, '
            'which is the only place it matters. (Doc comments are allowed '
            'to NAME `kDebugMode` in prose — e.g. to explain a log is '
            'deliberately not gated behind it — only real code usage fails '
            'this guard.)',
      );
    });
  });

  group('connection_native.dart is provably unchanged', () {
    test('reports durable BEFORE returning the executor', () {
      final source = _normalized(nativePath);
      final reportAt = source.indexOf('onStorageReport?.call(');
      final lazyAt = source.indexOf('return LazyDatabase(');
      expect(reportAt, greaterThan(-1));
      expect(lazyAt, greaterThan(-1));
      expect(
        reportAt,
        lessThan(lazyAt),
        reason:
            'native has nothing to probe, so it must already be in its '
            'final durable state on the very first frame',
      );
      expect(source, contains('StorageBackend.nativeFile'));
    });

    test('opens exactly the same database it always did', () {
      expect(
        _normalized(nativePath),
        contains(
          'return LazyDatabase(() async { '
          'final dir = await getApplicationDocumentsDirectory(); '
          "final file = File(p.join(dir.path, 'climbtopo.sqlite')); "
          'return NativeDatabase(file); });',
        ),
        reason:
            'iOS/Android must stay bit-identical: same documents '
            'directory, same filename, same NativeDatabase, still lazy',
      );
    });
  });
}
