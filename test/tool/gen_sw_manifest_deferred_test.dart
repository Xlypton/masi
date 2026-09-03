import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_sw_manifest.dart';

/// Pins the classification of dart2js DEFERRED PART files.
///
/// This exists because the failure it guards is silent in both directions and
/// invisible in a wasm-only build. `deferred as` makes dart2js emit
/// `main.dart.js_<n>.part.js` chunks; if the manifest generator does not
/// recognise them as part of the dart2js renderer bundle, they fall through to
/// the ordinary app-asset branch and get precached ATOMICALLY FOR EVERY
/// CLIENT — including every blink client, which runs dart2wasm and can never
/// execute a byte of them. Nothing errors, nothing logs; the install just
/// silently downloads the deferred features for the people the deferral was
/// supposed to spare, which is the exact opposite of the change's purpose.
void main() {
  group('dart2js deferred part files', () {
    test('are recognised as part of the dart2js renderer bundle', () {
      expect(isJsDeferredPart('main.dart.js_1.part.js'), isTrue);
      expect(isJsDeferredPart('main.dart.js_2.part.js'), isTrue);
      expect(isJsDeferredPart('main.dart.js_17.part.js'), isTrue);

      // The consequence that actually matters: renderer artifacts leave the
      // atomic precache and are fetched best-effort per client.
      expect(isRendererArtifact('main.dart.js_1.part.js'), isTrue);
      expect(isPrecacheExcluded('main.dart.js_1.part.js'), isTrue);
    });

    test('do not swallow ordinary app assets that merely look similar', () {
      // Over-matching is the mirror-image bug: a real app asset classified as
      // a renderer artifact would drop OUT of the atomic precache and stop
      // being guaranteed offline.
      expect(isJsDeferredPart('main.dart.js'), isFalse);
      expect(isJsDeferredPart('main.dart.js.map'), isFalse);
      expect(isJsDeferredPart('main.dart.mjs'), isFalse);
      expect(isJsDeferredPart('main.dart.wasm'), isFalse);
      expect(isJsDeferredPart('assets/main.dart.js_1.part.js'), isFalse);
      expect(isJsDeferredPart('main.dart.js_.part.js'), isFalse);
      expect(isJsDeferredPart('main.dart.js_1.part.js.map'), isFalse);
      expect(isJsDeferredPart('drift_worker.js'), isFalse);
      expect(isJsDeferredPart('sqlite3.wasm'), isFalse);
    });

    test('the entrypoint and the wasm bundle keep their existing meaning', () {
      // Guards the edit that "simplifies" the two lists into one.
      expect(isRendererArtifact('main.dart.js'), isTrue);
      expect(isRendererArtifact('main.dart.wasm'), isTrue);
      expect(isRendererArtifact('main.dart.mjs'), isTrue);
      expect(isRendererArtifact('sqlite3.wasm'), isFalse);
      expect(isRendererArtifact('drift_worker.js'), isFalse);
    });

    test('sqlite3.wasm and drift_worker.js stay in the ATOMIC precache', () {
      // The data layer cannot open at all without these two, so they are the
      // one thing that must never become best-effort. Stated as a test because
      // "it is a .wasm, like the renderer" is a plausible-sounding reason to
      // move them, and offline would break only for users who had not already
      // cached them.
      expect(isPrecacheExcluded('sqlite3.wasm'), isFalse);
      expect(isPrecacheExcluded('drift_worker.js'), isFalse);
    });
  });
}
