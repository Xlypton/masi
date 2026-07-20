import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Native (iOS/Android/desktop) connection — opens climbtopo.sqlite in the
/// app documents directory. Byte-identical to the pre-split implementation.
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'climbtopo.sqlite'));
    return NativeDatabase(file);
  });
}
