import 'storage_persistence_types.dart';

/// Inert fallback used on native (iOS/Android/desktop) and in plain-Dart
/// `flutter test`, i.e. whenever `dart.library.js_interop` is unavailable
/// (see `storage_persistence.dart`'s facade doc). There is no browser to ask
/// and nothing that evicts local data on those platforms, so this always
/// answers [StoragePersistOutcome.notApplicable] and touches nothing.
Future<StoragePersistOutcome> requestPersistentStorage() async =>
    StoragePersistOutcome.notApplicable;

/// See [requestPersistentStorage]. There is no browser storage bucket here,
/// so "is it persistent?" is always `false`. Callers must NOT read that as
/// "native storage is fragile" — [StoragePersistOutcome.notApplicable] from
/// [requestPersistentStorage] is what distinguishes "no such concept" from
/// "the browser said no".
Future<bool> isStoragePersisted() async => false;

/// See [requestPersistentStorage]. No `navigator.storage.estimate()` to read,
/// so usage/quota are unknown (`null`), never zero.
Future<StorageEstimateSnapshot?> estimateStorage() async => null;

/// See `listenForAppInstalled` in the web backend
/// (`storage_persistence_web.dart`) — no `window`/`appinstalled` event exists
/// here, so [onInstalled] is simply never called. Never throws, never
/// registers anything.
void listenForAppInstalled(void Function() onInstalled) {}
