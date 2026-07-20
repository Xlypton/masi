// Facade for the tile-fetch retry policy's "was this a plain socket-level
// network error" check (`community_screen.dart`'s
// `buildResilientTileHttpClient`). Conditional export picks the right
// backend for the running platform, exactly like `lib/core/db/connection/`
// and `lib/core/platform/ar_support.dart`:
//  - native (iOS/Android/desktop): a real `error is SocketException` check
//    (`dart:io`).
//  - web: always `false` — `dart:io`'s `SocketException` type doesn't exist
//    there, and a failed `fetch()` surfaces through `package:http` as a
//    `ClientException` instead (already checked separately by the retry
//    policy's `whenError`), so there is nothing this check would ever add.
//  - anything else: stub, same inert `false` behavior as web.
export 'retryable_error_stub.dart'
    if (dart.library.io) 'retryable_error_native.dart'
    if (dart.library.js_interop) 'retryable_error_web.dart';
