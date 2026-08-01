import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// Holds the path of the currently selected image, or null if none.
class SelectedImageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String path) => state = path;
  void clear() => state = null;
}

final selectedImageProvider = NotifierProvider<SelectedImageNotifier, String?>(
  SelectedImageNotifier.new,
);

/// Loads [wallId]'s persisted "original" photo (if any) via
/// [photoRepository], and, when found, loads its routes into
/// [drawController]'s state via [DrawController.loadForWall].
///
/// Extracted as a standalone, non-UI function taking its dependencies
/// directly (rather than a [WidgetRef], and rather than being inlined into
/// [_TopoCanvasScreenState]) precisely so the "restore a wall's persisted
/// photo/routes on open" contract is testable directly against a
/// [ProviderContainer]'s `photoRepositoryProvider` /
/// `drawControllerProvider.notifier` — no widget pump, no [WidgetRef] (which
/// is `sealed` in riverpod 3 and so cannot be faked in tests), and no real
/// image decode required (see
/// `test/features/topo/application/topo_canvas_wall_binding_test.dart`).
///
/// UNCONDITIONAL reset (cross-wall leak fix): [drawController.beginPhotoSwitch]
/// is called — and [onReset], if given, is invoked — synchronously, BEFORE
/// the async [photoRepository.loadOriginal] call even starts, and regardless
/// of whether a photo is ultimately found. Previously the only reset was
/// [beforeLoadForWall] below, which only ever ran when a photo WAS found;
/// entering a wall with no photo yet left [drawControllerProvider] (and, via
/// [onReset], `selectedImageProvider`) holding whatever the
/// PREVIOUSLY-viewed wall had left there — both are app-lifetime globals,
/// not per-wall state. Concretely, without this: navigating from a
/// wall A that has a photo+routes to a wall B that has none would show B's
/// screen with A's photo and routes still on screen, AND leave
/// `state.activeWallId == A`, so drawing+committing on B would silently
/// persist to wall A. Resetting first — synchronously, before the `await`
/// below — closes that: `activeWallId` becomes null immediately (so a stray
/// commit mid-load can't reach ANY wall's persisted routes — see
/// [DrawController.beginPhotoSwitch]'s doc), and the screen falls back to its
/// own empty state rather than the previous wall's image, for exactly as
/// long as wall B genuinely has nothing to show.
///
/// [beforeLoadForWall], if given, is invoked synchronously with the found
/// photo right before [DrawController.loadForWall] is called. This exists so
/// [_TopoCanvasScreenState] can select the photo's path (showing the image)
/// at exactly the right moment: [SelectedImageNotifier.select] synchronously
/// triggers this screen's `ref.listen` callback in `build`
/// ([DrawController.beginPhotoSwitch] + clearing the transform), which must
/// run BEFORE `loadForWall` populates fresh wall/route state, or
/// that synchronous clear would immediately wipe out what was just loaded.
/// (For the has-photo path, this means [DrawController.beginPhotoSwitch] is
/// invoked twice — once unconditionally above, once via that listener when
/// [beforeLoadForWall] selects the path — which is harmless: the second call
/// finds state already clear, then `loadForWall` proceeds exactly as before.)
///
/// FIX #4 (continued): the no-photo branch calls
/// [DrawController.cancelPhotoSwitch] before returning — [beginPhotoSwitch]
/// above opens a switch that, with no photo to load, [DrawController
/// .loadForWall] will never run to close out. Without this call
/// [DrawState.isSwitchingPhoto] would stay stuck `true`, and the NEXT
/// [DrawController.beginPhotoSwitch] (for whatever wall is entered after
/// this photo-less one) would wrongly treat that stale flag as "a switch
/// is still in flight" and carry forward any stray routes committed on
/// this photo-less wall's empty canvas into the NEXT wall's freshly-loaded
/// state instead of discarding them — see [DrawController.cancelPhotoSwitch]'s
/// doc for the full regression this closes.
Future<PhotoRef?> loadWallOriginalPhoto(
  PhotoRepository photoRepository,
  DrawController drawController,
  String wallId, {
  void Function(PhotoRef photo)? beforeLoadForWall,
  void Function()? onReset,
}) async {
  final generation = drawController.beginPhotoSwitch();
  onReset?.call();

  final photo = await photoRepository.loadOriginal(wallId);
  if (photo == null) {
    drawController.cancelPhotoSwitch(generation);
    return null;
  }
  beforeLoadForWall?.call(photo);
  await drawController.loadForWall(wallId, photo.id);
  return photo;
}

/// Resolves the app-owned path for the just-attached photo [photoId] via
/// [libraryRepo] and, if it differs from [pickedPath] (the transient
/// picker-cache path [_TopoCanvasScreenState._pickImage] originally
/// selected), updates [selectedImage] to hold the owned path instead.
/// Returns whichever path ends up current (the owned path, or [pickedPath]
/// unchanged if [libraryRepo].attachPhotoToWall's copy never happened/failed
/// and the row still points at [pickedPath]).
///
/// This is the fix for a confirmed photo-ownership bug: [attachPhotoToWall]
/// copies a freshly-picked file into the app-owned `<appDocuments>/photos/`
/// directory and stores THAT path on the new row, but only returns the new
/// photo's id (see that method's doc) — `selectedImageProvider` itself was
/// left holding whatever raw path `_pickImage` selected before the attach
/// even started, for the rest of the session (a stale, OS-evictable
/// picker-cache path rather than the owned copy) until the wall was
/// reopened.
///
/// [libraryRepo].photoLocalPath is a direct primary-key lookup by [photoId]
/// — unlike `PhotoRepository.loadOriginal`'s wallId+kind query, it can never
/// throw on a wall that has accumulated more than one live `'original'` row
/// (e.g. from replacing a wall's photo more than once), so re-reading the
/// owned path this way is safe even in that case.
///
/// Extracted as a standalone function taking [libraryRepo] and
/// [selectedImage] (a [SelectedImageNotifier], not a [WidgetRef]) directly
/// — mirroring [loadWallOriginalPhoto]'s own extraction above — so this
/// fix's contract is directly testable against a [ProviderContainer]'s
/// `libraryCrudRepositoryProvider`/`selectedImageProvider`: no widget pump,
/// no real image decode (see
/// `test/features/library/data/photo_ownership_test.dart`'s "S1 regression"
/// group, which exercises exactly this).
Future<String> resolveAttachedPhotoPath(
  LibraryCrudRepository libraryRepo,
  SelectedImageNotifier selectedImage,
  String photoId,
  String pickedPath,
) async {
  final ownedPath = await libraryRepo.photoLocalPath(photoId) ?? pickedPath;
  if (ownedPath != pickedPath) {
    selectedImage.select(ownedPath);
  }
  return ownedPath;
}

/// A [SnackBar] presenting [error]'s [PhotoWriteException.userMessage] behind a
/// warning glyph — the user-facing half of the L3 fix, replacing a
/// `debugPrint` no user could ever see.
///
/// Mirrors `topo_canvas_gps.dart`'s [gpsCaptureResultSnackBar] shape so both
/// photo-attach outcomes read identically, and lives HERE rather than inline in
/// either screen because BOTH photo-attach entry points must present the same
/// words for the same failure: the Topos-home "New topo" flow
/// (`topos_screen.dart`'s `_handleNewTopo`) and the canvas add/replace-photo
/// flow (`topo_canvas_screen.dart`'s `_attachPhotoAndLoad`).
SnackBar photoWriteFailureSnackBar(PhotoWriteException error) {
  return SnackBar(
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MasiIcon('warning', size: 18),
        const SizedBox(width: 8),
        Flexible(child: Text(error.userMessage)),
      ],
    ),
  );
}

/// A [SnackBar] presenting [error]'s [RouteWriteException.userMessage] behind a
/// warning glyph — the route-side twin of [photoWriteFailureSnackBar], for UF-1
/// (a route write that never reached the database).
///
/// Deliberately the same shape as the photo version rather than a new
/// treatment: a climber whose device is out of room can hit BOTH in one session
/// (the photo attach, then the route commit), and two different-looking
/// warnings for one underlying problem read as two unrelated faults.
///
/// [DrawController] has already reverted the canvas by the time this is shown
/// (see `DrawController._writeThrough`), so the route/marker/grade is gone from
/// the screen. This is what turns that disappearance from a glitch into an
/// explanation — present it from a `ref.listen` on
/// `DrawState.lastWriteFailure`, then call
/// [DrawController.clearWriteFailure] so the next failure registers as a new
/// change. Follow `topo_canvas_screen.dart`'s existing `DrawState.mode`
/// listener for the no-`fireImmediately` pattern.
SnackBar routeWriteFailureSnackBar(RouteWriteException error) {
  return SnackBar(
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MasiIcon('warning', size: 18),
        const SizedBox(width: 8),
        Flexible(child: Text(error.userMessage)),
      ],
    ),
  );
}

/// Settles the canvas after a photo attach failed on its BYTE WRITE, and
/// returns the [SnackBar] the caller should show.
///
/// Three things must happen together, which is exactly why they live in one
/// function rather than three lines in a catch block:
///  - [selectedImage] is CLEARED. `TopoCanvasScreen._pickImage` selects the
///    picked path optimistically (so the screen shows a spinner for it
///    immediately), but with the write failed there is no [db.Photos] row
///    behind that path and never will be — leaving it selected strands the
///    canvas on an image it can neither load nor persist against.
///  - [drawController]'s switch [generation] is settled via
///    [DrawController.cancelPhotoSwitch]. See `_attachPhotoAndLoad`'s FIX #4
///    doc: EVERY exit path must settle the switch it opened, or
///    `DrawState.isSwitchingPhoto` stays stuck `true` and corrupts the next
///    `beginPhotoSwitch`'s routes handling.
///  - the user is told why, in plain words.
///
/// Extracted as a standalone function taking its collaborators directly —
/// mirroring [loadWallOriginalPhoto]/[resolveAttachedPhotoPath] above —
/// because `TopoCanvasScreen._pickImage` calls the module-level
/// `showPhotoSourceSheet`/`pickPhotoFrom` with NO injectable seam, so a widget
/// test cannot drive the canvas pick flow at all. This makes the failure path
/// testable against a plain `ProviderContainer` instead (see
/// `test/features/topo/application/topo_canvas_wall_binding_test.dart`).
SnackBar settleFailedPhotoAttach(
  SelectedImageNotifier selectedImage,
  DrawController drawController,
  int generation,
  PhotoWriteException error,
) {
  selectedImage.clear();
  drawController.cancelPhotoSwitch(generation);
  return photoWriteFailureSnackBar(error);
}
