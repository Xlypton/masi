import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/supabase_config.dart';
import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/push_registration.dart';

/// Whether this device currently receives push, and the work to change that.
///
/// The state is the browser's own answer, re-read rather than remembered: the
/// user can revoke notifications in site settings at any time and nothing tells
/// the page when they do, so a cached "granted" would leave the switch on while
/// every send silently went nowhere.
class PushRegistration extends AsyncNotifier<PushPermission> {
  static const _uuid = Uuid();

  @override
  Future<PushPermission> build() async {
    // Rebuilt on identity change: a subscription belongs to a device AND an
    // account, and signing in as somebody else must not leave the previous
    // user's row pointed at this endpoint.
    ref.watch(effectiveUidProvider);
    return pushPermission();
  }

  /// Asks the browser, then records the resulting endpoint against the
  /// signed-in user.
  ///
  /// Returns true only if this device will now actually receive a push.
  ///
  /// **Only meaningful from a user gesture** — see [subscribeToPush]. Wired to
  /// a switch the user taps, never to app start, which is also the honest
  /// design: an app that asks for notification permission before you have used
  /// it is one you say no to.
  Future<bool> enable() async {
    final uid = ref.read(effectiveUidProvider);
    if (uid == null) return false;

    state = const AsyncValue.loading();
    try {
      final subscription = await subscribeToPush(vapidPublicKey);
      if (subscription == null) {
        state = AsyncValue.data(pushPermission());
        return false;
      }
      await _upsert(uid, subscription);
      state = AsyncValue.data(pushPermission());
      return pushPermission() == PushPermission.granted;
    } catch (error, stack) {
      debugPrint('masi/push: enable failed: $error');
      state = AsyncValue.error(error, stack);
      return false;
    }
  }

  /// Stops push on this device: drops the browser subscription and retires the
  /// server row.
  ///
  /// Deliberately does NOT try to revoke the notification PERMISSION — no API
  /// can, and pretending otherwise would leave the user thinking they had
  /// undone something they had not. Losing the subscription is what actually
  /// stops the sends.
  Future<void> disable() async {
    final uid = ref.read(effectiveUidProvider);
    final subscription = await currentPushSubscription();
    await unsubscribeFromPush();

    if (uid != null && subscription != null) {
      try {
        await ref
            .read(supabaseClientProvider)
            .from('push_subscriptions')
            .delete()
            .eq('endpoint', subscription.endpoint)
            .eq('ownerId', uid);
      } catch (error) {
        // The browser subscription is already gone, so the endpoint is dead and
        // the sender will retire the row itself on the next 410. Not worth
        // failing the user's action over.
        debugPrint('masi/push: could not remove the server row: $error');
      }
    }
    state = AsyncValue.data(pushPermission());
  }

  /// Writes the endpoint, keyed by endpoint so a device that re-subscribes
  /// updates its row rather than accumulating a new one every launch.
  Future<void> _upsert(String uid, PushSubscriptionData subscription) async {
    final now = ref.read(nowMsProvider)();
    await ref.read(supabaseClientProvider).from('push_subscriptions').upsert({
      'id': _uuid.v4(),
      'ownerId': uid,
      'endpoint': subscription.endpoint,
      'p256dh': subscription.p256dh,
      'auth': subscription.auth,
      'userAgent': subscription.userAgent,
      'createdAt': now,
      'updatedAt': now,
      // Clears any previous retirement: this endpoint is demonstrably alive
      // again, and leaving the tombstone would mean the sender kept skipping a
      // device the user just re-enabled.
      'failedAt': null,
    }, onConflict: 'endpoint');
  }
}

final pushRegistrationProvider =
    AsyncNotifierProvider<PushRegistration, PushPermission>(
      PushRegistration.new,
    );
