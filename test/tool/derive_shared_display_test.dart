// The one-off backfill tool duplicates two constants because it cannot import
// the Flutter-bound file that owns them. This keeps the duplicate honest: a
// tool deriving a different size or quality than the app would publish
// variants the app would never have produced.
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/sync_remote.dart';

import '../../tool/derive_shared_display.dart' as tool;

void main() {
  test('the backfill tool derives exactly what the app publishes', () {
    expect(tool.displayMaxEdge, kSharedDisplayMaxEdge);
    expect(tool.displayQuality, kSharedDisplayQuality);
  });
}
