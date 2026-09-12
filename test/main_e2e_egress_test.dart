// The E2E harness must not pay for other climbers' photo bytes.
//
// This is a COST guard, and it is here because the bug it pins is invisible
// from inside the app: a driven run that downloads 110 MB of foreign photo
// originals behaves EXACTLY like one that downloads none — same assertions,
// same screenshots, same green. The only place it showed up was a Supabase
// quota email (2026-09-12), after the fact, once the month's allowance was
// already spent.
//
// So there is no behavioural test that would catch a regression here. A
// reviewer removing the override would see nothing go red, which is precisely
// why the check has to be explicit.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/sync_service.dart'
    show kSharedPhotoByteBudgetPerPull;
import 'package:masi/main_e2e.dart';

void main() {
  test('the app itself keeps the real foreign-photo budget', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(sharedPhotoByteBudgetProvider),
      kSharedPhotoByteBudgetPerPull,
      reason:
          'only the E2E entrypoint may cap this — capping it in the app would '
          'silently stop climbers seeing each other\'s photos',
    );
  });

  test('every E2E boot caps foreign photo downloads at zero', () {
    final container = ProviderContainer(overrides: e2eBootOverrides());
    addTearDown(container.dispose);

    expect(
      container.read(sharedPhotoByteBudgetProvider),
      0,
      reason:
          'a driven run is always a COLD pull, so the default budget is ~110 MB '
          'of Storage egress per run — ~52 runs is the whole monthly free-tier '
          'allowance, and the suite never asserts on a foreign photo\'s pixels',
    );
  });

  test('the cap applies in REAL mode, not just FAKE', () {
    // The mode that signs in for real is the mode that actually downloads:
    // FAKE carries no JWT and 401s on every server call. So a cap that lived
    // only in `e2eOverrides()` (which REAL mode deliberately skips, to keep
    // the auth wall under test) would cap only the mode that never spent
    // anything. Asserting on the shared list directly pins that split.
    final container = ProviderContainer(overrides: e2eSharedOverrides());
    addTearDown(container.dispose);

    expect(container.read(sharedPhotoByteBudgetProvider), 0);
  });

  test('every photo upload sets an immutable cache-control', () {
    // A source guard, not a behavioural one: the header is handed to the
    // Supabase client, so nothing short of a live upload observes it, and the
    // default it replaces (one hour) is silent — an object served with it is
    // byte-identical to one served with a year.
    //
    // The value that matters is the ABSENCE of a bare `FileOptions(upsert:
    // true)`: that is the shape every upload in this file had before
    // 2026-09-12, and the shape a new upload will be copy-pasted into.
    final source = File(
      'lib/features/backup/data/sync_remote.dart',
    ).readAsStringSync();

    expect(
      source.contains('FileOptions(upsert: true)'),
      isFalse,
      reason:
          'a photo object is immutable — its key carries the photo id and its '
          'bytes never change under that key — so it must not be uploaded with '
          "Storage's mutable-object default of max-age=3600",
    );
    expect(
      RegExp('cacheControl: kPhotoObjectCacheControl').allMatches(source),
      hasLength(4),
      reason: 'all four upload sites (own, shared original, shared thumb, and '
          'the thumb backfill) must carry it',
    );
  });
}
