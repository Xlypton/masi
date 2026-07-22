import 'ar_channel.dart';

/// Web factory: a no-op [ArChannel] (see [ArChannel.noop]) — there is no
/// native `masi/ar` platform-channel handler on web, so a real
/// [ArChannel] would throw `MissingPluginException` on every call.
ArChannel createArChannel() => ArChannel.noop();
