import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:masi/core/location/location_service.dart';
import 'package:masi/core/location/photo_gps.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The outcome of a single [captureWallGpsFromPhoto] call, surfaced to the
/// caller so it can tell the user whether (and how) a location was found
/// for the photo just attached — see the "indicator" feature this backs:
/// a [SnackBar] via [gpsCaptureResultSnackBar] reporting exactly this.
enum GpsCaptureResult {
  /// The photo itself carried EXIF GPS tags, and the wall's coordinates
  /// were set (or updated) from them.
  exif,

  /// The photo had no EXIF GPS, but the wall had no coordinates yet and a
  /// device location was available, so that was recorded instead.
  deviceFallback,

  /// Neither EXIF GPS nor an applicable device-location fallback: no EXIF
  /// tags, AND either no device location was available, the wall already
  /// had coordinates (the fallback only ever fills a void — see below), or
  /// an error occurred. The wall's coordinates are unchanged in every case.
  none,
}

/// Reads the file at [path]'s bytes and, if they carry EXIF GPS tags (see
/// `core/location/photo_gps.dart`'s [extractGpsFromImageBytes]), records
/// them on [wallId] via [libraryRepo.setWallCoordinates].
///
/// Returns a [GpsCaptureResult] describing what happened, so callers (see
/// [_attachPhotoAndLoad] and `topos_screen.dart`'s `_handleNewTopo`) can
/// show the user a SnackBar reflecting it via [gpsCaptureResultSnackBar].
///
/// [locationService], if given, backs a fallback for the common no-EXIF
/// case (screenshots, downloaded images, GPS-less cameras): when the photo
/// itself carries no GPS, [LocationService.currentLocation] is asked for
/// the DEVICE's current position instead, and — if one is available —
/// THAT is recorded on [wallId]. EXIF always wins when both are present:
/// the fallback is only ever attempted after an EXIF read comes back null.
/// Passing no [locationService] (the default) simply skips the fallback,
/// leaving the pre-existing EXIF-only behavior unchanged (and returns
/// [GpsCaptureResult.none] whenever there's no EXIF GPS, exactly as if the
/// fallback had been attempted and come back empty).
///
/// Data-corruption fix: the device-location fallback only ever fills a
/// VOID — it is attempted ONLY when [wallId] has no coordinates yet (see
/// [LibraryCrudRepository.wallHasCoordinates]). This function runs on
/// EVERY photo attach, including REPLACING a wall's existing photo (the
/// canvas's add/replace-photo action): without this guard, a wall correctly
/// geotagged from its first photo's real EXIF GPS at the crag would have
/// those coordinates silently overwritten by wherever the device happens to
/// be — e.g. the user's home — the moment its photo is later replaced with
/// a no-EXIF image (a screenshot, a downloaded photo). EXIF GPS itself is
/// NOT subject to this guard: an EXIF read on a replacement photo always
/// updates [wallId]'s coordinates, even overwriting existing ones — that is
/// explicit, user-chosen photo data, not an incidental device position.
///

/// Extracted as a standalone function taking [libraryRepo] and a plain
/// [xfile] directly — mirroring [loadWallOriginalPhoto]/
/// [resolveAttachedPhotoPath]'s own extraction above — so this is directly
/// testable against a real [LibraryCrudRepository] and a real (or
/// hand-built fixture) file on disk: no widget pump and no `FileImage`/
/// `ui.instantiateImageCodec` decode required
/// (see `test/features/topo/presentation/topo_canvas_gps_test.dart`).
///
/// Never throws: a missing/unreadable file, bytes with no EXIF GPS AND no
/// (or no available) device location, resolves to [GpsCaptureResult.none]
/// rather than throwing — this is deliberately best-effort, exactly like
/// [extractGpsFromImageBytes] and [LocationService.currentLocation]
/// themselves, so missing location data of either kind never blocks or
/// breaks the surrounding photo attach/load flow.
Future<GpsCaptureResult> captureWallGpsFromPhoto(
  LibraryCrudRepository libraryRepo,
  String wallId,
  XFile xfile, {
  LocationService? locationService,
}) async {
  try {
    final bytes = await xfile.readAsBytes();
    final gps = await extractGpsFromImageBytes(bytes);
    if (gps != null) {
      await libraryRepo.setWallCoordinates(
        wallId,
        gps.latitude,
        gps.longitude,
      );
      return GpsCaptureResult.exif;
    }

    // No EXIF GPS -- fall back to the device's current location, but ONLY
    // to fill a VOID: if the wall already has coordinates (e.g. from a
    // previous photo's real EXIF GPS at the crag), a replacement photo with
    // no EXIF GPS must never silently overwrite them with wherever the
    // device happens to be right now -- see this function's doc for the
    // data-corruption scenario this guards against.
    if (await libraryRepo.wallHasCoordinates(wallId)) {
      return GpsCaptureResult.none;
    }

    final device = await locationService?.currentLocation();
    if (device == null) return GpsCaptureResult.none;
    await libraryRepo.setWallCoordinates(
      wallId,
      device.latitude,
      device.longitude,
    );
    return GpsCaptureResult.deviceFallback;
  } catch (_) {
    // Best-effort: a missing file, decode hiccup, or location failure must
    // never break the photo attach/load flow this runs alongside.
    return GpsCaptureResult.none;
  }
}

/// The user-facing message for [result], shared by both flows that call
/// [captureWallGpsFromPhoto] — this screen's own add/replace-photo action
/// ([_attachPhotoAndLoad]) and the Topos home's "New topo" flow
/// (`topos_screen.dart`'s `_handleNewTopo`) — so the wording is identical
/// for the same underlying outcome no matter which flow produced it.
String gpsCaptureResultMessage(GpsCaptureResult result) => switch (result) {
  GpsCaptureResult.exif => 'Location found in photo',
  GpsCaptureResult.deviceFallback => 'Location set from your current position',
  GpsCaptureResult.none => 'No location found in photo',
};

/// A [SnackBar] presenting [gpsCaptureResultMessage] for [result] — with a
/// leading place-pin icon whenever a location was actually captured
/// ([GpsCaptureResult.exif] or [GpsCaptureResult.deviceFallback]), omitted
/// for [GpsCaptureResult.none] so that neutral "nothing found" case reads
/// plainly rather than implying a location was set.
SnackBar gpsCaptureResultSnackBar(GpsCaptureResult result) {
  final foundLocation = result != GpsCaptureResult.none;
  return SnackBar(
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (foundLocation) ...[
          MasiIcon('pin', size: 18),
          const SizedBox(width: 8),
        ],
        Flexible(child: Text(gpsCaptureResultMessage(result))),
      ],
    ),
  );
}
