import 'package:drift/drift.dart';

import 'storage_durability.dart';

/// See `connection_web.dart`'s declaration for what this means and why it
/// exists. No connection can be opened here at all, so nothing will ever read
/// it; `false` keeps the parity signature honest rather than implying a flush
/// this platform could perform.
const bool commitNeedsExplicitFlush = false;

/// Fallback used when neither dart:io nor dart:js_interop is available.
///
/// [onStorageReport] exists purely for signature parity across the
/// conditional-export seam — this implementation never reaches the point of
/// having a verdict to report.
QueryExecutor openConnection({
  void Function(StorageDurability verdict)? onStorageReport,
}) =>
    throw UnsupportedError('No database connection available on this platform.');
