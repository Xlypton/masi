/// AR is supported on web via the browser's camera + a manual-only
/// alignment (no continuous ARKit/ARCore session exists in a browser) — see
/// [arSupportsAutoTracking]. Always `true`.
bool isArSupported() => true;

/// Web has no continuous ARKit/ARCore tracking session — there is no
/// browser API for real-time 6DOF pose/feature tracking, so only the
/// manual (static) alignment mode is available. Always `false`.
bool arSupportsAutoTracking() => false;

/// There is no `dart:io` `File` on web, and AR extraction never runs here
/// anyway, so this is always `false`.
bool photoFileExistsSync(String path) => false;
