// Derives one `shared/display/` variant from an original, with the APP'S OWN
// resampler — so a variant written by `tool/backfill_shared_display.sh` is
// byte-for-byte the object `SharedDerivativeBackfill` would have written.
//
//   dart run tool/derive_shared_display.dart <original> <out.jpg>
//
// Imports `image_ops_native.dart` directly rather than `sync_remote.dart`'s
// `generateSharedDisplayImage`: the latter pulls in Flutter and Supabase, which
// `dart run` cannot load, while the native image op is pure `package:image`.
// The two constants below therefore duplicate `kSharedDisplayMaxEdge` and
// `kSharedDisplayQuality`; `test/tool/derive_shared_display_test.dart` fails if
// they drift apart.
import 'dart:io';

import 'package:masi/features/topo/data/image_ops/image_ops_native.dart';

const int displayMaxEdge = 2048;
const int displayQuality = 85;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/derive_shared_display.dart <in> <out>');
    exit(2);
  }
  final src = await File(args[0]).readAsBytes();
  final out = await generateThumbnail(
    src,
    maxEdge: displayMaxEdge,
    quality: displayQuality,
  );
  await File(args[1]).writeAsBytes(out);
  stdout.writeln('${src.length} -> ${out.length}');
}
