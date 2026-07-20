import 'dart:io';

/// Native: a plain `dart:io` type check, exactly what
/// `buildResilientTileHttpClient`'s `whenError` used to do directly before
/// this became a conditional-export facade (see `retryable_error.dart`'s
/// doc for why it had to move out of the shared file).
bool isSocketException(Object error) => error is SocketException;
