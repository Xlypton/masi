// The `shared/display/` tier — the mid-size variant the pull fetches instead
// of a foreign photo's full-resolution original.
//
// WHY IT EXISTS, since the numbers are the justification: this project's real
// bucket holds 35 shared originals averaging 5.5 MB (straight-off-the-phone
// JPEGs, 68 of 118 objects between 4 and 8 MB). The pull fetched those, so one
// cold pull moved ~110 MB and roughly 52 of them was the entire monthly
// Storage egress allowance — which is how it ran out on 2026-09-12.
//
// The tier is only SAFE because route geometry is stored normalized to the
// image's width/height (`TopoRoute`), so a line drawn on the original lands in
// the same place on any downscale. That is the load-bearing precondition, and
// the reason this file asserts the derivation is a pure resize rather than a
// crop or a pad.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:masi/features/backup/data/sync_remote.dart';

void main() {
  Uint8List jpegOf(int width, int height) {
    final image = img.Image(width: width, height: height);
    // Real detail, not a flat fill: a flat image compresses to almost nothing
    // and would make the size assertion below pass for the wrong reason.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x ^ y) % 256);
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 92));
  }

  test('a phone-sized original is resized to the 2048px cap', () async {
    final original = jpegOf(4000, 3000);

    final display = await generateSharedDisplayImage(original);
    final decoded = img.decodeImage(display)!;

    expect(decoded.width, kSharedDisplayMaxEdge);
    expect(
      decoded.height,
      1536,
      reason: 'aspect ratio must be preserved exactly — 4000x3000 is 4:3, so '
          'a 2048 long edge is 1536 short. A crop or a pad here would move '
          'every normalized route anchor on the photo',
    );
    expect(
      display.length,
      lessThan(original.length ~/ 3),
      reason: 'the whole point is the size cut; on the real corpus this is '
          'measured ~4.3x (185 MB -> 43 MB)',
    );
  });

  test('the long edge is capped whichever edge it is', () async {
    final portrait = await generateSharedDisplayImage(jpegOf(3000, 4000));
    final decoded = img.decodeImage(portrait)!;

    expect(decoded.height, kSharedDisplayMaxEdge);
    expect(decoded.width, 1536);
  });

  test('an already-small original is returned byte-identical', () async {
    // `generateThumbnail`'s documented short-circuit, and the reason the caller
    // contract requires publish-safe (EXIF-stripped) bytes: an unresized image
    // comes back VERBATIM, metadata and all, so handing it raw bytes would
    // publish a GPS location.
    final small = jpegOf(800, 600);

    expect(await generateSharedDisplayImage(small), same(small));
  });

  test('the display tier is a sibling of the thumb tier, not nested in it', () {
    expect(sharedDisplayPath('abc'), 'shared/display/abc.jpg');
    expect(sharedThumbPath('abc'), 'shared/thumbs/abc.jpg');
  });

  test('the display path ignores the original extension, like the thumb', () {
    // Both derivations re-encode to JPEG, so the extension is a property of the
    // derivation. This is what lets a `display/<id>.jpg` key be derived from an
    // id that no longer remembers whether its original was .png or .JPG — the
    // exact trap `isThumbKey` documents.
    expect(sharedDisplayPath('abc'), endsWith(kSharedDisplayExt));
    expect(sharedPhotoPath('abc', '.png'), 'shared/abc.png');
  });

  test('a display variant is never larger than the thumbnail tier is small',
      () async {
    // Guards against the two constants being swapped, which would silently
    // make the canvas tier the 512px one.
    expect(kSharedDisplayMaxEdge, greaterThan(512));
    expect(kSharedDisplayQuality, greaterThan(80));
  });
}
