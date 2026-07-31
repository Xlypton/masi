import 'package:drift/drift.dart';

import 'storage_durability.dart';

/// Fallback used when neither dart:io nor dart:js_interop is available.
///
/// [onStorageReport] exists purely for signature parity across the
/// conditional-export seam — this implementation never reaches the point of
/// having a verdict to report.
QueryExecutor openConnection({
  void Function(StorageDurability verdict)? onStorageReport,
}) =>
    throw UnsupportedError('No database connection available on this platform.');
