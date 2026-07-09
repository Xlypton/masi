import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/ar/application/ar_channel.dart';

/// Supplies the [ArChannel] used by [ArController] to talk to the native AR
/// platform channel. Overridable in tests (e.g. to inject an [ArChannel]
/// backed by mock/fake `MethodChannel`/`EventChannel` instances).
final arChannelProvider = Provider<ArChannel>((ref) => ArChannel());

/// The AR feature's UI-facing state: the current [ArMode], the most recent
/// [ArAlignment] pushed from native (or null before the first update), and
/// whether the AR session is currently active (started on native).
class ArState {
  const ArState({required this.mode, this.latest, required this.active});

  final ArMode mode;
  final ArAlignment? latest;
  final bool active;

  ArState copyWith({ArMode? mode, ArAlignment? latest, bool? active}) {
    return ArState(
      mode: mode ?? this.mode,
      latest: latest ?? this.latest,
      active: active ?? this.active,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArState &&
        other.mode == mode &&
        other.latest == latest &&
        other.active == active;
  }

  @override
  int get hashCode => Object.hash(mode, latest, active);

  @override
  String toString() =>
      'ArState(mode: $mode, latest: $latest, active: $active)';
}

/// Holds [ArState] and mediates mode changes/alignment updates for the AR
/// feature.
///
/// This controller is deliberately thin: it does NOT itself start/stop the
/// native session or subscribe to [ArChannel.alignments] — the AR screen
/// (which owns the widget lifecycle) is responsible for calling
/// [ArChannel.start]/[ArChannel.stop] and forwarding each [ArAlignment] from
/// the stream into [onAlignment]. This keeps the controller synchronously
/// testable without a running platform channel/stream.
class ArController extends Notifier<ArState> {
  @override
  ArState build() => const ArState(mode: ArMode.auto, active: false);

  /// Switches the alignment mode: updates [ArState.mode] and forwards the
  /// change to native via [ArChannel.setMode].
  void setMode(ArMode mode) {
    state = state.copyWith(mode: mode);
    ref.read(arChannelProvider).setMode(mode);
  }

  /// Records the latest alignment update pushed from native (see the AR
  /// screen's subscription to [ArChannel.alignments]).
  void onAlignment(ArAlignment alignment) {
    state = state.copyWith(latest: alignment);
  }

  /// Marks whether the native AR session is currently active (started).
  void markActive(bool active) {
    state = state.copyWith(active: active);
  }
}

final arControllerProvider = NotifierProvider<ArController, ArState>(
  ArController.new,
);
