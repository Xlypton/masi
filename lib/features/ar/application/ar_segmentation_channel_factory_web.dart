import 'ar_segmentation_channel.dart';

/// Web factory: a no-op [ArSegmentationChannel] (see
/// [ArSegmentationChannel.noop]) — there is no native `masi/arSegmentation`
/// platform-channel handler on web, so a real [ArSegmentationChannel] would
/// throw `MissingPluginException` on every call.
ArSegmentationChannel createArSegmentationChannel() =>
    ArSegmentationChannel.noop();
