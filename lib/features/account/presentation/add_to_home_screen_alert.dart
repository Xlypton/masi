import 'package:flutter/widgets.dart';

import '../../../shared/presentation/masi_dialogs.dart';

/// The iOS install fallback: Safari exposes no programmatic install API, so
/// the best the app can do is explain the manual Share-sheet steps.
///
/// Lives here, on its own, because it has TWO callers — `install_banner.dart`
/// and `account_screen.dart`'s `_InstallSection` — which until now each held
/// a byte-identical private copy (the banner's even said "copied from" in its
/// doc comment). Two copies of one string is two places for the copy to drift.
Future<void> showAddToHomeScreenAlert(BuildContext context) => showMasiAlert(
  context,
  title: 'Add to Home Screen',
  message: 'To install: tap the Share button in your browser, then choose '
      "'Add to Home Screen'.",
  dialogKey: const Key('add-to-home-screen-dialog'),
);
