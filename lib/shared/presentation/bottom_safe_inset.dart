import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/features/account/application/pwa_install_providers.dart';

/// How much room bottom-anchored chrome must leave when the platform reports
/// none — i.e. the home indicator's worth of space.
///
/// Matches the floor `NavShell` has always applied to the nav bar, because the
/// nav bar is the one piece of bottom chrome that has looked right, and the
/// point of this constant is that everything else looks like it.
const double kStandaloneBottomFloor = 32; // MasiSpacing.xxl

/// The bottom clearance a screen's own bottom-anchored chrome should use.
///
/// ## The bug this exists to fix
///
/// In an installed iOS PWA, iOS reports `safe-area-inset-bottom = 0` (the
/// status-bar style is 'default'), so **every `SafeArea` and every
/// `MediaQuery.padding.bottom` in the app evaluates to zero** and bottom
/// chrome lands on the home indicator. `NavShell` has always compensated for
/// its own bar; nothing else did, which is why the nav bar looked right and
/// the topo canvas's route panel, the sheets and the toasts all looked
/// cramped.
///
/// ## Why `max`, and why that makes this safe to use anywhere
///
/// The app has two worlds, and a naive fix breaks one of them:
///
///  - **Inside `NavShell`** (`/`, `/map`, `/feed`) the `SafeArea` carrying the
///    floor IS the `bottomNavigationBar`, and `Scaffold` rewrites the body's
///    `MediaQuery.padding.bottom` to the measured height of that bar. So those
///    screens already read a value that CONTAINS the floor. Adding a floor on
///    top would leave 32px of dead space on the three most-used screens.
///  - **Everywhere else** there is no bar, so the same read is zero.
///
/// Taking `max(deviceInset, floor)` collapses both cases into one rule: inside
/// the shell the measured inset already exceeds the floor and wins unchanged;
/// outside it, the floor applies. That is the same `max()` semantics
/// `SafeArea(minimum:)` uses, and it is what lets callers use this without
/// first working out which world they are in — a distinction that is invisible
/// at the call site and was never going to be applied correctly by hand across
/// two dozen widgets.
///
/// **Combine it with `max`, never by addition.** A caller that writes
/// `masiBottomInset(...) + MasiSpacing.lg` is asking for 48px; that is fine
/// when the spacing is a deliberate gap above the inset, and wrong when the
/// spacing was itself standing in for the missing inset. Read the call site.
///
/// **Keyboard insets are orthogonal.** `MediaQuery.viewInsets.bottom` is the
/// keyboard, not the home indicator; a sheet wants `max(this, keyboard)`, not
/// their sum, or it jumps by a floor's worth the moment the keyboard opens.
double masiBottomInset(BuildContext context, WidgetRef ref) {
  return math.max(
    MediaQuery.paddingOf(context).bottom,
    ref.watch(pwaInstallStatusProvider).isStandalone
        ? kStandaloneBottomFloor
        : 0.0,
  );
}

/// The floor on its own, for callers that hand it to `SafeArea(minimum:)`
/// rather than computing a padding value themselves.
///
/// Zero unless the app is running as an installed PWA — a desktop browser has
/// no home indicator to clear, and forcing the floor there would just be dead
/// space. `SafeArea(minimum:)` already takes a per-edge `max` against the real
/// device inset, so this never double-counts.
double standaloneBottomFloorOf(WidgetRef ref) =>
    ref.watch(pwaInstallStatusProvider).isStandalone
    ? kStandaloneBottomFloor
    : 0.0;

/// [masiBottomInset] for code that already holds a [WidgetRef] but no longer
/// has a [BuildContext] it trusts — e.g. a callback that captured `ref`.
///
/// Prefer [masiBottomInset]. This exists because a `SnackBar` is built by the
/// `ScaffoldMessenger`, whose context is not the screen's.
double masiBottomInsetOf(WidgetRef ref, {required double deviceInset}) {
  return math.max(
    deviceInset,
    ref.read(pwaInstallStatusProvider).isStandalone
        ? kStandaloneBottomFloor
        : 0.0,
  );
}
