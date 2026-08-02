/// Paging for Supabase Storage object listings.
///
/// S6 (silent 100-object truncation): `StorageFileApi.list()` takes
/// `searchOptions: SearchOptions(limit:, offset:, sortBy:, search:)` whose
/// defaults are `limit: 100, offset: 0, sortBy: name asc`
/// (`storage_client-2.6.0/lib/src/types.dart:217-222`), and the endpoint
/// returns AT MOST `limit` objects with no total count and no "there is more"
/// flag. A single un-paged `list(path: …)` therefore TRUNCATES any prefix
/// holding more than 100 objects — which is exactly how the sync push's
/// "already uploaded" skip-set went stale past ~100 photos, making every push
/// re-read and re-upload bytes already in the cloud. Originals are kept at FULL
/// resolution (decision D-5), so that re-upload is the dominant push cost AND
/// the dominant window for the byte phase to fail.
///
/// Deliberately its own file rather than a private method on
/// `SupabaseSyncRemote`: three listings need it (`SyncRemote`'s private and
/// shared prefixes, plus `BackupRemote.listPhotoObjectPaths`, whose identical
/// duplicate is a known divergence risk), and keeping it free of every Supabase
/// type makes the paging LOOP itself unit-testable against a plain fetcher —
/// no `SupabaseClient` fake, no network.
library;

/// Page size used for every paged Storage listing — the storage client's own
/// `SearchOptions` default, restated here so the loop and the request it issues
/// can never drift apart.
const int kStoragePageSize = 100;

/// Collects EVERY item a paged listing can return.
///
/// [fetchPage] receives `(limit, offset)` and must behave exactly like the
/// Storage `list()` endpoint: return at most `limit` items, starting at
/// `offset`, in a stable order.
///
/// A SHORT page — fewer than `limit` items, the empty page included — is the
/// ONLY termination signal the REST contract offers, so it is the only one used
/// here. A page that comes back exactly full therefore always costs one more
/// request; that is correct rather than wasteful, since it is the sole way to
/// distinguish "exactly one page of objects" from "the first of several".
///
/// [pageSize] defaults to [kStoragePageSize]; tests shrink it to keep fixtures
/// small. A non-positive value would spin forever and is rejected.
Future<List<T>> collectPagedObjects<T>(
  Future<List<T>> Function(int limit, int offset) fetchPage, {
  int pageSize = kStoragePageSize,
}) async {
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
  }
  final all = <T>[];
  var offset = 0;
  while (true) {
    final page = await fetchPage(pageSize, offset);
    all.addAll(page);
    if (page.length < pageSize) return all;
    offset += page.length;
  }
}
