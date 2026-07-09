import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';

/// Manages the list of pending vertical cut positions for the slice-creation
/// tool: fractions of the image's width, each strictly inside `(0.0, 1.0)`.
///
/// The state list is always kept sorted ascending (re-sorted on every
/// [addCut]), so consumers (e.g. [SliceTool] and [commit]) can rely on
/// ascending order directly from `ref.watch(sliceControllerProvider)` without
/// a separate `sortedCuts` getter. The list itself is always replaced with a
/// new list instance on mutation — never mutated in place — so Riverpod's
/// equality check reliably notifies listeners.
class SliceController extends Notifier<List<double>> {
  @override
  List<double> build() => const [];

  /// Appends a new cut at [x]. Values at or beyond the image boundaries
  /// (`x <= 0.0` or `x >= 1.0`) are ignored, since they wouldn't produce a
  /// valid interior cut (see [slicesFromCuts]). The resulting list is
  /// re-sorted ascending.
  void addCut(double x) {
    if (x <= 0.0 || x >= 1.0) return;
    state = [...state, x]..sort();
  }

  /// Removes whichever cut in the list is closest to [x]. No-op if there are
  /// no pending cuts.
  void removeNearestCut(double x) {
    if (state.isEmpty) return;

    var nearestIndex = 0;
    var nearestDistance = (state[0] - x).abs();
    for (var i = 1; i < state.length; i++) {
      final distance = (state[i] - x).abs();
      if (distance < nearestDistance) {
        nearestIndex = i;
        nearestDistance = distance;
      }
    }

    final next = [...state]..removeAt(nearestIndex);
    state = next;
  }

  /// Empties the cut list.
  void clear() {
    state = const [];
  }

  /// Commits the current cuts: derives [SliceSpec]s via [slicesFromCuts] and
  /// persists them via [repo].replaceSlices, then [clear]s the cut list.
  ///
  /// No-ops and returns `false` (without touching [repo] at all) if there
  /// are no pending cuts — committing an empty slice tool would otherwise
  /// silently replace any existing slices with a single full-width slice,
  /// which is never what "commit with nothing drawn" should mean. Returns
  /// `true` once slices have been persisted.
  ///
  /// Deliberately free of any Flutter UI/BuildContext dependency so it can
  /// be unit tested directly against an in-memory [PhotoRepository] (see
  /// `slice_controller_test.dart`) without a real image decode; the
  /// presentation layer (`TopoCanvasScreen`) only adds UI concerns
  /// (mounted-guard, snackbar-on-empty, exiting slice mode) around this
  /// call.
  Future<bool> commit(
    PhotoRepository repo, {
    required String wallId,
    required String originalPhotoId,
    required int originalWidth,
    required int originalHeight,
    required String originalLocalPath,
  }) async {
    if (state.isEmpty) return false;

    final specs = slicesFromCuts(state);
    await repo.replaceSlices(
      wallId,
      originalPhotoId,
      originalWidth,
      originalHeight,
      originalLocalPath,
      specs,
    );
    clear();
    return true;
  }
}

final sliceControllerProvider = NotifierProvider<SliceController, List<double>>(
  SliceController.new,
);
