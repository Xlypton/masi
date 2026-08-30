import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_synthesis.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';

/// Turns a wall's photo rows into the layout engine's inputs.
///
/// Pure and separate from the provider so the mapping — in particular that
/// `sortOrder` IS capture order — can be tested without a database. There is
/// no separate capture-order column precisely because this mapping is the
/// whole of it: `sortOrder` starts as the upload sequence and changes only
/// when a human reorders the rail, which is exactly the rule the spec states
/// for capture order.
List<FaceInput> faceInputsFrom(List<PhotoRef> photos) => [
  for (final photo in photos)
    FaceInput(
      id: photo.id,
      captureOrder: photo.sortOrder,
      latitude: photo.captureLatitude,
      longitude: photo.captureLongitude,
      gpsAccuracyMeters: photo.captureAccuracyMeters,
      bearingDegrees: photo.captureBearingDegrees,
      pinnedT: photo.layoutPinnedT,
    ),
];

/// How many climbs each of a wall's photos shows, live.
///
/// The face rail badges every thumbnail with this, which is the one thing a
/// plain dot never said: not just that there are four sides, but which of them
/// has the climbing on it. Absent from the map means none — see
/// `RouteRepository.watchRouteCountsByPhoto`.
final wallRouteCountsProvider =
    StreamProvider.autoDispose.family<Map<String, int>, String>(
  (ref, wallId) =>
      ref.watch(routeRepositoryProvider).watchRouteCountsByPhoto(wallId),
);

/// The wall columns the engine needs, live.
final wallLayoutAnchorProvider =
    StreamProvider.autoDispose.family<WallLayoutAnchor?, String>(
  (ref, wallId) =>
      ref.watch(libraryCrudRepositoryProvider).watchWallLayoutAnchor(wallId),
);

/// The resolved layout for a wall: where every photo sits along the rock.
///
/// Recomputed from scratch whenever a photo, a pin or the stroke changes,
/// which is the spec's step 5 ("topology is a computed property of current
/// data") falling straight out of Riverpod rather than needing an
/// invalidation scheme. `resolveLayout` is pure and cheap, so there is
/// nothing to cache and nothing to get stale.
///
/// Emits [LayoutResult.empty] for a wall with no photos rather than an error:
/// a topo with nothing in it has an empty layout, which every consumer can
/// render, and no failure to report.
final wallLayoutProvider =
    Provider.autoDispose.family<AsyncValue<LayoutResult>, String>((
  ref,
  wallId,
) {
  final photos = ref.watch(wallOriginalsProvider(wallId));
  final anchor = ref.watch(wallLayoutAnchorProvider(wallId));

  // The anchor is allowed to still be loading: a layout computed with no
  // authored stroke is a correct provisional layout, not a wrong one, and
  // waiting for it would flash an empty topo on every open. The stroke lands
  // a frame later and the layout recomputes.
  return photos.whenData((rows) {
    if (rows.isEmpty) return LayoutResult.empty;
    final wall = anchor.value;
    final stored = Baseline.decode(wall?.baselineJson);
    return resolveLayout(
      faces: faceInputsFrom(rows),
      baseline: stored,
      origin: stored == null
          ? BaselineOrigin.captureOrderStrip
          : BaselineOrigin.authored,
      originLatitude: wall?.latitude,
      originLongitude: wall?.longitude,
    );
  });
});
