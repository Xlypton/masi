// This file used to hold both Community screens (`CommunityMapScreen` and
// `CommunityFeedScreen`) plus all their private supporting widgets in one
// ~2,450-line god-file. It's now split by cohesion into
// `community_map_screen.dart` (the Map tab + `_MapView`/marker/legend
// widgets + the resilient-tile-provider helpers) and
// `community_feed_screen.dart` (the Feed tab + `_FeedView`/row/badge
// widgets). The one widget both tabs shared, `PendingIconButton`, has since
// been promoted to `lib/shared/presentation/masi_pending_icon_button.dart`
// (three other features wanted it), so there is no `community_shared.dart`
// any more.
//
// This file stays in place and re-exports both screens (plus the
// `@visibleForTesting` tile-provider seams `community_screen_test.dart`
// exercises directly) so every existing importer — `router.dart`,
// `set_location_picker.dart`, and the community test suite — keeps
// resolving with NO edit required.
export 'community_feed_screen.dart' show CommunityFeedScreen;
export 'community_map_screen.dart'
    show
        CommunityMapScreen,
        buildResilientTileHttpClient,
        buildResilientTileProvider,
        debugResilientTileClientCreateCount,
        debugResilientTileClientCloseCount,
        debugResetResilientTileClientCounters;
