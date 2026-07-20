/// Web: `dart:io`'s `SocketException` type doesn't exist here — see
/// `retryable_error.dart`'s doc for why this always returns `false` rather
/// than trying to detect the equivalent browser-side failure.
bool isSocketException(Object error) => false;
