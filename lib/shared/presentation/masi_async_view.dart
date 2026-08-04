import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import 'masi_icon.dart';
import 'masi_loading_gate.dart';
import 'masi_pending_button.dart';

/// Renders an [AsyncValue] with the four states it actually has — first load,
/// refresh, data, failure — instead of the three `.when()` invites.
///
/// This replaces the `asyncThing.when(data: ..., loading: () => const
/// Center(child: CircularProgressIndicator()), error: ...)` pattern. That
/// pattern is wrong three times over: it shows a bare spinner where the shape
/// of the content is perfectly well known, it BLANKS data the user already had
/// whenever the provider refreshes, and its error branch usually just prints a
/// sentence with nothing to press.
///
/// ```dart
/// MasiAsyncView<List<Area>>(
///   value: ref.watch(areasProvider),
///   onRetry: () => ref.invalidate(areasProvider),
///   errorMessage: "Couldn't load your areas",
///   skeleton: (context) => const MasiSkeletonList.listRows(),
///   data: (context, areas) => _AreaList(areas: areas),
/// )
/// ```
///
/// ## The four states
///
/// | [AsyncValue]                     | Rendered                              |
/// |----------------------------------|---------------------------------------|
/// | loading, no previous value       | [skeleton] (after the reveal delay)   |
/// | loading, HAS a previous value    | [data] + a hairline activity cue      |
/// | error, no previous value         | [errorMessage] + **Retry**            |
/// | error, HAS a previous value      | [data] + a non-destructive failure bar|
/// | data                             | [data]                                |
///
/// The two "HAS a previous value" rows are the point of this widget. In
/// Riverpod v3 a refreshed provider emits an [AsyncValue] with
/// `isLoading == true` **and** `hasValue == true` (`isRefreshing`/`isReloading`
/// distinguish why), and an [AsyncError] can likewise still carry the last
/// good `value`. A plain `.when()` treats both as "loading"/"error" and throws
/// the content away, so a pull-to-refresh or a failed re-fetch wipes a list
/// the user was reading. Here, existing content is never replaced — the state
/// is reported *around* it.
///
/// Timing comes from [MasiLoadingGate], so neither the skeleton nor the
/// refresh cue can flash: nothing appears for [MasiMotion.loadingRevealDelay],
/// and once it does it stays [MasiMotion.loadingMinVisible].
///
/// **Layout.** This is a screen-BODY widget: it lays its states out in a
/// [Column] with the content [Expanded], so it must be given a bounded height
/// (a [Scaffold.body], an [Expanded], a sized box). That is deliberately
/// uniform across all four states — a widget that only broke its constraints
/// on the day a refresh failed would be a trap. It is not a sliver; inside a
/// [CustomScrollView] use it above/around the scroll view, not in it.
///
/// There is deliberately no sliver variant. The app's one [CustomScrollView]
/// (`community_topo_detail_screen.dart`) has no single async value to render:
/// it composes four independent ones — wall name, likes, comments, routes — each
/// with its own skeleton, its own failure and a header that must render whatever
/// they do. A sliver version of THIS widget would still want to own the whole
/// scroll view's content, which is the wrong shape there; that screen uses
/// [MasiLoadingGate] plus a per-section failure notice instead. Build the sliver
/// variant when a screen turns up that a single [AsyncValue] genuinely drives.
///
/// **Testing.** The skeleton shimmers and the refresh cue animates, so
/// `pumpAndSettle()` will hang on this widget in its loading states — use
/// `tester.pump(duration)`. To reach the revealed skeleton, pump past
/// [MasiMotion.loadingRevealDelay]; to prove the anti-flash, pump less than it
/// and assert the skeleton is absent.
///
/// Two more test traps, both of which cost real time to diagnose:
///
///  - The error state mounts a [MasiIcon], i.e. an ASYNC SVG load, which
///    schedules extra frames. `pumpAndSettle()` therefore advances more fake
///    time than the assertions expect, and Riverpod v3's default backoff retry
///    fires more often — re-running the throwing provider body mid-assertion and
///    leaving pending timers at teardown. Build the container with
///    `ProviderContainer(retry: (_, _) => null)` in any test that drives a
///    failing provider through this widget. (Measured: without it, a test that
///    deliberately errors two providers HANGS rather than fails.)
///  - [onRetry]'s cue is a [MasiPendingButton], so once a retry is in flight the
///    error state contains a live spinner and `pumpAndSettle()` hangs on it too.
class MasiAsyncView<T> extends StatelessWidget {
  const MasiAsyncView({
    super.key,
    required this.value,
    required this.data,
    required this.skeleton,
    required this.onRetry,
    this.errorMessage = "Couldn't load this",
    this.showErrorDetail = false,
  });

  /// Usually `ref.watch(someAsyncProvider)`.
  final AsyncValue<T> value;

  /// The real content.
  final Widget Function(BuildContext context, T data) data;

  /// The first-load placeholder. Use a shaped skeleton
  /// (`MasiSkeletonList.listRows()`, a card/canvas skeleton) whenever the
  /// content's shape is known — a `MasiLoadingIndicator.standalone()` here is
  /// a last resort, not the default.
  final WidgetBuilder skeleton;

  /// Retry. Required and non-nullable on purpose: before this widget the app
  /// had no retry affordance anywhere, and for a Riverpod screen there is
  /// always a correct answer — `() => ref.invalidate(theProvider)`.
  ///
  /// [FutureOr] so both shapes stay ergonomic. A synchronous
  /// `() => ref.invalidate(p)` is still the common answer and needs no `async`;
  /// return a future (`() => ref.refresh(p.future)`) and the Try-again button
  /// shows a pending cue for as long as the re-fetch runs, which is what
  /// essentially every retry here actually is — a network pull.
  final FutureOr<void> Function() onRetry;

  /// The human sentence for the failure state. Say what could not be loaded
  /// ("Couldn't load your areas"), never "Error".
  final String errorMessage;

  /// Whether to print the raw error under [errorMessage].
  ///
  /// **Off by default.** An exception's `toString()` is developer text: it names
  /// types, tables and columns, and at least one feature has a deliberate,
  /// test-asserted rule against putting any of it in front of a user. Opt in
  /// (`showErrorDetail: true`) on the local-first surfaces where the raw text is
  /// frequently the only diagnosis available on a release build on a phone
  /// (see #72) — that is a decision per screen, not a default.
  final bool showErrorDetail;

  /// Key on the error state's container.
  static const Key errorKey = Key('masi-async-error');

  /// Key on the error state's Retry button.
  static const Key retryKey = Key('masi-async-retry');

  /// Key on the hairline cue shown while refreshing over existing data.
  static const Key refreshCueKey = Key('masi-async-refresh-cue');

  /// Key on the bar shown when a refresh FAILED but existing data is kept.
  static const Key staleErrorKey = Key('masi-async-stale-error');

  @override
  Widget build(BuildContext context) {
    // Read the value's three orthogonal facts rather than pattern-matching the
    // subclass: in Riverpod v3 they overlap by design (an AsyncData can be
    // loading; an AsyncError can hold a value).
    final hasValue = value.hasValue;
    final isLoading = value.isLoading;
    final hasError = value.hasError;

    // ONE gate wraps every state, and the branch choice happens INSIDE its
    // builder. That structure is load-bearing, not stylistic: the gate's
    // minimum-visible hold has to survive the exact transition it exists to
    // smooth — data arriving. An earlier version chose the branch outside the
    // gate, so `hasValue` flipping to true switched away from the skeleton
    // immediately and the hold held nothing: a skeleton revealed at 180 ms
    // whose data landed at 190 ms still strobed.
    return MasiLoadingGate(
      // First load only. A refresh has content to keep, so it must never put a
      // skeleton up; it gets the hairline cue from the inner gate below.
      isLoading: isLoading && !hasValue && !hasError,
      builder: (context, showSkeleton) {
        // True for the whole hold, including after the value has arrived —
        // which is the point.
        if (showSkeleton) return skeleton(context);

        if (!hasValue) {
          // No content to protect: a failure with nothing behind it, or the
          // anti-flash window before a skeleton is allowed on screen. Error
          // wins over loading — a retrying provider still has a failure worth
          // reporting.
          if (hasError) return _errorState(context);
          // Deliberately blank, not a spinner: a load that resolves inside the
          // reveal delay must paint no loading state at all.
          return const SizedBox.shrink();
        }

        // From here on there IS content, so it stays on screen no matter what.
        final content = data(context, value.value as T);
        if (hasError) {
          return Column(
            children: [
              _staleErrorBar(context),
              Expanded(child: content),
            ],
          );
        }

        return MasiLoadingGate(
          isLoading: isLoading,
          builder: (context, showCue) => Column(
            children: [
              // A 2 px hairline above the content, not over it: an overlay on
              // top of a list intercepts nothing but does cover a row, and a
              // full-screen scrim during a refresh is exactly the "blank the
              // data you already have" mistake in a different costume.
              _RefreshCue(visible: showCue),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  /// Adapts [onRetry]'s [FutureOr] to what [MasiPendingButton] awaits. A
  /// synchronous retry simply resolves inside the reveal delay, so it paints no
  /// cue at all — the anti-flash rule doing its job rather than a special case.
  Future<void> _runRetry() async => onRetry();

  Widget _errorState(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final detail = showErrorDetail ? value.error?.toString() : null;

    return Center(
      key: errorKey,
      child: Padding(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('warning', size: 40, color: colors.gradeHard),
            const SizedBox(height: MasiSpacing.md),
            Text(
              errorMessage,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: colors.ink),
            ),
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: MasiSpacing.sm),
              Text(
                detail,
                textAlign: TextAlign.center,
                // An exception's toString() can be a paragraph; the same cap
                // `SyncBanner` puts on its detail line.
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: colors.ink2),
              ),
            ],
            const SizedBox(height: MasiSpacing.md),
            // A pending button, not a plain one: [onRetry] is almost always a
            // network pull, and a Try-again that looks idle for three seconds
            // gets tapped again.
            MasiPendingButton.filled(
              buttonKey: retryKey,
              onPressed: _runRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  /// The failed-refresh-over-good-data state: say so, offer the retry, and
  /// touch nothing below. Visually a sibling of `SyncBanner` (same tinted
  /// fill + border recipe) so a screen showing both reads as one stack of
  /// notices.
  Widget _staleErrorBar(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: staleErrorKey,
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.md,
        MasiSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.gradeHard.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: colors.gradeHard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon('warning', size: 22, color: colors.gradeHard),
          const SizedBox(width: MasiSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    "$errorMessage — showing what's already here.",
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                  ),
                ),
                const SizedBox(height: MasiSpacing.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MasiPendingButton.text(
                    buttonKey: retryKey,
                    onPressed: _runRetry,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Try again'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The refresh activity cue: a 2 px indeterminate accent hairline that takes
/// up its own 2 px of layout whether or not it is [visible], so content does
/// not shift down when a refresh starts.
///
/// Under reduced motion it renders as a static partial bar rather than a
/// travelling one — `MasiShimmer`'s freeze-a-frame approach again.
class _RefreshCue extends StatelessWidget {
  const _RefreshCue({required this.visible});

  final bool visible;

  static const double _thickness = 2;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    if (!visible) {
      return const SizedBox(height: _thickness, width: double.infinity);
    }
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return RepaintBoundary(
      key: MasiAsyncView.refreshCueKey,
      child: SizedBox(
        height: _thickness,
        width: double.infinity,
        child: Semantics(
          label: 'Refreshing',
          child: LinearProgressIndicator(
            value: reduceMotion ? 0.35 : null,
            minHeight: _thickness,
            backgroundColor: Colors.transparent,
            color: colors.accent,
          ),
        ),
      ),
    );
  }
}
