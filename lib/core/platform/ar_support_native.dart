import 'dart:io';

/// Whether the native AR camera/ARKit surface is available on this platform.
/// AR only ships on iOS in this app (no Android platform-view/ARCore
/// implementation exists) — see `ar_support.dart`'s facade doc.
bool isArSupported() => Platform.isIOS;

/// A cheap, synchronous existence check for a local file path — used to
/// gate spawning the (real, background-isolate) ghost-outline extraction in
/// `ArScreen._load` without ever awaiting a doomed `compute()` call for a
/// path that can't resolve on this host. Native-only: pulls in `dart:io`'s
/// `File`, which must never be referenced from web-compiled code.
bool photoFileExistsSync(String path) => File(path).existsSync();
