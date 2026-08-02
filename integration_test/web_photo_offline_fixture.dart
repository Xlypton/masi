// Shared fixture for the two halves of the chained photo-durability run.
//
//   tool/drive_web_photo_offline.sh
//     -> integration_test/web_photo_offline_seed_test.dart      (run 1)
//     -> integration_test/web_photo_offline_verify_test.dart    (run 2)
//
// The two runs are separate `flutter drive` invocations, i.e. separate Chrome
// PROCESSES. They only ever meet through:
//
//   * the browser's own on-disk storage — same `--web-port` (one origin) and
//     same `--user-data-dir` (one Chrome profile), so run 2 opens the exact
//     IndexedDB databases run 1 wrote; and
//   * a handful of `--dart-define`s the shell script threads through.
//
// Nothing in Dart memory survives between them, which is the entire point:
// run 2 is a genuine cold start, strictly stronger than an F5.
//
// This file is deliberately NOT named `*_test.dart` — it holds no tests, and
// `flutter test` must not pick it up.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Identifies one chained seed+verify pair.
///
/// Passed to BOTH runs by `tool/drive_web_photo_offline.sh` as
/// `--dart-define=MASI_PHOTO_RUN=<epoch>`. Every row and every pixel this
/// fixture produces is derived from it, so a stale row left in a warm Chrome
/// profile by an earlier pair can never satisfy a later one's assertions.
const String kRunStamp = String.fromEnvironment(
  'MASI_PHOTO_RUN',
  defaultValue: 'unstamped',
);

/// Byte length of the photo run 1 stored, handed to run 2 by the script,
/// which reads it out of run 1's `build/integration_response_data.json`.
///
/// Empty when run 2 is invoked standalone; the verify test then falls back to
/// re-deriving the fixture from [kRunStamp] and says so in its report data.
const String kExpectedPhotoLen = String.fromEnvironment('MASI_PHOTO_LEN');

/// FNV-1a/64 digest of the same bytes — see [fnv1a64].
const String kExpectedPhotoHash = String.fromEnvironment('MASI_PHOTO_HASH');

/// The wall run 1 created. Threaded through rather than re-derived so run 2
/// asserts against the SAME row, not merely a same-named one.
const String kExpectedWallId = String.fromEnvironment('MASI_PHOTO_WALL');

/// The IndexedDB key run 1's bytes landed under (`photos/<photoId>.jpg`).
const String kExpectedPhotoKey = String.fromEnvironment('MASI_PHOTO_KEY');

/// Seconds run 1 holds the page open after its last write, before the
/// browser is killed.
///
/// This exists because the two halves of a photo become durable on different
/// schedules: `IdbPhotoByteStore` commits the pixels synchronously with its
/// IndexedDB transaction, while the `Photos` row lives in drift's sqlite
/// image, which the `sharedIndexedDb` backend persists lazily from a
/// SharedWorker. Making the window a knob rather than a constant is what
/// turns "the row vanished" into a measurement.
const int kSettleSeconds = int.fromEnvironment(
  'MASI_PHOTO_SETTLE',
  defaultValue: 15,
);

String get areaName => 'Offline Photo Area $kRunStamp';
String get sectorName => 'Offline Photo Sector $kRunStamp';
String get wallName => 'Offline Photo Wall $kRunStamp';

/// The filename handed to `PhotoFiles.importPhoto`, whose extension decides
/// the IndexedDB key (`photos/<photoId>.jpg`).
String get photoFileName => 'offline-$kRunStamp.jpg';

/// A content digest with no package dependency.
///
/// Deliberately not `package:crypto` (not a dependency here) and deliberately
/// not "same length" — a truncated or zero-filled read must fail this, and
/// only a byte-for-byte match may pass.
///
/// Two independent rolling hashes rather than one FNV-1a/64, because this
/// runs in a DDC-compiled debug web build where `int` is a JS double: a
/// 64-bit FNV needs `BigInt` to stay exact, and a BigInt multiply per byte
/// over a ~100 KB photo is orders of magnitude slower there than in a
/// release build. Both multipliers below keep every intermediate under 2^53,
/// so the arithmetic is exact on the JS number type with no BigInt at all.
/// Combined with the separately-asserted length, this is far more than
/// enough to tell "the same bytes" from "different bytes".
String fnv1a64(List<int> bytes) {
  var h1 = 0x1505; // djb2-style, multiplier 33
  var h2 = 0x0801; // sdbm-style, multiplier 65599
  for (final byte in bytes) {
    final b = byte & 0xff;
    h1 = (h1 * 33 + b) & 0x1FFFFFFF; // < 2^29 * 33  ≈ 1.8e10
    h2 = (h2 * 65599 + b) & 0x0FFFFFFF; // < 2^28 * 65599 ≈ 1.8e13
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}'
      '${h2.toRadixString(16).padLeft(8, '0')}';
}

/// Builds the photo both runs agree on, deterministically from [kRunStamp].
///
/// Two properties matter, and they pull in different directions:
///
///  * It must be a REAL JPEG. `PhotoFiles.importPhoto` derives a thumbnail
///    from it and the canvas hands it to the browser's image decoder — a
///    buffer of noise would exercise neither.
///  * It must be VISUALLY UNMISTAKABLE in a screenshot. The whole point of
///    this pair is that a human (or an agent) looks at run 2's PNG and sees
///    the photo. So: saturated blocks in a fixed order, plus the run stamp
///    drawn large in the middle. If those digits are legible in run 2's
///    screenshot, the bytes that produced them came out of browser storage
///    written by a different browser process — there is no other path.
Uint8List buildPhotoBytes() {
  const width = 900;
  const height = 600;
  final image = img.Image(width: width, height: height);

  // A flat, saturated background nothing in the app's chrome resembles.
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width - 1,
    y2: height - 1,
    color: img.ColorRgb8(18, 22, 40),
  );

  // Four corner blocks, fixed colours, so orientation and cropping are
  // readable at a glance.
  const blockW = 220;
  const blockH = 150;
  final corners = <List<Object>>[
    [0, 0, img.ColorRgb8(255, 0, 170)], // magenta  top-left
    [width - blockW, 0, img.ColorRgb8(0, 230, 255)], // cyan     top-right
    [0, height - blockH, img.ColorRgb8(255, 214, 0)], // yellow   bottom-left
    [width - blockW, height - blockH, img.ColorRgb8(0, 255, 120)], // green
  ];
  for (final corner in corners) {
    final x = corner[0] as int;
    final y = corner[1] as int;
    img.fillRect(
      image,
      x1: x,
      y1: y,
      x2: x + blockW - 1,
      y2: y + blockH - 1,
      color: corner[2] as img.Color,
    );
  }

  // A centre band + the stamp, large enough to read in a 1600x1024 shot.
  img.fillRect(
    image,
    x1: 0,
    y1: (height ~/ 2) - 70,
    x2: width - 1,
    y2: (height ~/ 2) + 70,
    color: img.ColorRgb8(250, 250, 250),
  );
  img.drawString(
    image,
    'MASI OFFLINE',
    font: img.arial48,
    x: 40,
    y: (height ~/ 2) - 60,
    color: img.ColorRgb8(10, 10, 10),
  );
  img.drawString(
    image,
    kRunStamp,
    font: img.arial48,
    x: 40,
    y: (height ~/ 2) - 8,
    color: img.ColorRgb8(190, 0, 90),
  );

  // quality 92: high enough that the blocks stay flat and the digits stay
  // legible after a round trip through the browser's decoder.
  return img.encodeJpg(image, quality: 92);
}

/// Hosts used to prove the browser really has no network.
///
/// `--proxy-server=127.0.0.1:1` must break all of these while leaving the
/// app's own origin working (Chrome bypasses the proxy for loopback). The
/// Supabase host is the one that actually matters to this app.
const List<String> kExternalProbeUrls = <String>[
  'https://mnaipcqbkqzffgvxpato.supabase.co/auth/v1/health',
  'https://example.com/',
];

/// Result of asking the browser to reach the outside world.
class NetworkProbe {
  const NetworkProbe({required this.url, required this.reachable, this.detail});

  final String url;
  final bool reachable;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'reachable': reachable,
    if (detail != null) 'detail': detail,
  };
}

/// Attempts a real cross-origin GET from inside the page.
///
/// A severed browser answers with a `ClientException` — fetch rejects
/// because the connection to the (nonexistent) proxy fails, before any name
/// is even looked up. Note what "reachable: false" does and does not prove:
/// it proves the browser could not complete the request, which is exactly
/// the condition the offline claim needs. It does not distinguish that from
/// a CORS rejection — which is why the probe list includes a host this app
/// genuinely talks to, and why the severance is also asserted from the shell
/// side by the flag that produced it.
Future<NetworkProbe> probeExternal(String url) async {
  try {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 8));
    return NetworkProbe(
      url: url,
      reachable: true,
      detail: 'HTTP ${response.statusCode}',
    );
  } on TimeoutException {
    return NetworkProbe(url: url, reachable: false, detail: 'timeout');
  } catch (error) {
    return NetworkProbe(
      url: url,
      reachable: false,
      detail: error.runtimeType.toString(),
    );
  }
}

/// Pumps real frames until [condition] holds, or [timeout] elapses.
///
/// `pumpAndSettle` is unusable for boot waits here for the same reason it is
/// in `web_offline_persistence_test.dart`: the app holds live `StreamProvider`
/// subscriptions and an indeterminate progress indicator, so "no more frames
/// scheduled" may never arrive.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return condition();
}
