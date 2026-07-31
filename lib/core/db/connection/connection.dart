// Facade for the local-database connection.
//
// `storage_durability.dart` is the platform-AGNOSTIC half (the verdict
// vocabulary every platform reports in, plus its release-visible log) and is
// exported unconditionally; the conditional export below then picks the right
// backend for the running platform. Same two-part shape as
// `lib/features/topo/data/photo_files.dart`.
export 'storage_durability.dart';
export 'connection_stub.dart'
    if (dart.library.io) 'connection_native.dart'
    if (dart.library.js_interop) 'connection_web.dart';
