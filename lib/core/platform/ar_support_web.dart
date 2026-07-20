/// AR (the native `UiKitView`/ARKit camera surface) never runs on web — no
/// camera/ARKit surface exists there. Always `false`.
bool isArSupported() => false;

/// There is no `dart:io` `File` on web, and AR extraction never runs here
/// anyway (see [isArSupported]), so this is always `false`.
bool photoFileExistsSync(String path) => false;
