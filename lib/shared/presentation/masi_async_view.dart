import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import 'masi_icon.dart';
import 'masi_loading_gate.dart';

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
/// **Testing.** The skeleton shimmers and the refresh cue animates, so
/// `pumpAndSettle()` will hang on this widget in its loading states — use
/// `tester.pump(duration)`. To reach the revealed skeleton, pump past
/// [MasiMotion.loadingRevealDelay]; to prove the anti-flash, pump less than it
/// and assert the skeleton is absent.
class MasiAsyncView<T> extends StatelessWidget {
  const MasiAsyncView({
    super.key,
    required this.value,
    required this.data,
    required this.skeleton,
    required this.onRetry,
    this.errorMessage = "Couldn't load this",
    this.showErrorDetail = true,
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
  final VoidCallback onRetry;

  /// The human sentence for the failure state. Say what could not be loaded
  /// ("Couldn't load your areas"), never "Error".
  final String errorMessage;

  /// Whether to print the raw error under [errorMessage]. On by default: this
  /// app is local-first and the raw text is frequently the only diagnosis
  /// available on a release build on a phone (see #72). Turn it off where the
  /// error object is known to be noise.
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

    if (!hasValue) {
      // Nothing to protect: this is a first load, or a failure with no
      // previous content. Error wins over loading — a retrying provider still
      // has a failure worth reporting.
      if (hasError) return _errorState(context);
      return MasiLoadingGate(
        isLoading: isLoading,
        builder: (context, showLoading) => showLoading
            ? skeleton(context)
            // Deliberately blank, not a spinner: this is the anti-flash
            // window, and the whole point is that a load which resolves
            // inside it paints no loading state at all.
            : const SizedBox.shrink(),
      );
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
      builder: (context, showLoading) => Column(
        children: [
          // A 2 px hairline above the content, not over it: an overlay on top
          // of a list intercepts nothing but does cover a row, and a
          // full-screen scrim during a refresh is exactly the "blank the data
          // you already have" mistake in a different costume.
          _RefreshCue(visible: showLoading),
          Expanded(child: content),
        ],
      ),
    );
  }

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
            ElevatedButton(
              key: retryKey,
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
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
                  child: TextButton(
                    key: retryKey,
                    onPressed: onRetry,
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
