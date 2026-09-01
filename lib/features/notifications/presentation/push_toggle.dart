import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/pwa_install_providers.dart';
import '../../account/application/pwa_install_types.dart';
import '../application/push_providers.dart';
import '../data/push_registration.dart';

/// Turns push notifications on for THIS device.
///
/// Per device, not per account, and the wording says so — a subscription is
/// issued by the browser to one installation, so switching this on here does
/// nothing for the same climber's laptop. Presenting it as an account setting
/// would promise something it cannot deliver.
///
/// Renders nothing at all when push cannot work here (native builds, a browser
/// without the Push API, signed out). An inert switch invites a tap that does
/// nothing, and a disabled one invites a hunt for why.
class PushToggle extends ConsumerWidget {
  const PushToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final signedIn = ref.watch(effectiveUidProvider) != null;
    final async = ref.watch(pushRegistrationProvider);
    final permission = async.value;

    if (!signedIn || permission == null) return const SizedBox.shrink();
    if (permission == PushPermission.unsupported) {
      return const _IosInstallHint();
    }

    final granted = permission == PushPermission.granted;
    final denied = permission == PushPermission.denied;

    return Padding(
      key: const Key('push-toggle'),
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.sm,
        MasiSpacing.lg,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(MasiSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(MasiRadii.card),
        ),
        child: Row(
          children: [
            MasiIcon(
              'flash',
              size: 20,
              color: granted ? colors.accent : colors.ink3,
            ),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Notify this device',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // Three different sentences, because they are three
                    // different situations and only one of them is actionable
                    // here. A blocked permission cannot be reopened by any API
                    // — only the user can, in site settings — so saying "turn
                    // it on" would be sending them to a button that is
                    // guaranteed to do nothing.
                    denied
                        ? 'Blocked in your browser settings for this site'
                        : granted
                        ? 'Alerts reach this device even when Masi is closed'
                        : 'Get alerted even when Masi is closed',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.ink2),
                  ),
                ],
              ),
            ),
            if (async.isLoading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(
                key: const Key('push-toggle-switch'),
                value: granted,
                // `null` rather than a no-op callback: Switch renders itself
                // visibly disabled, which is the honest look for a state the
                // app cannot change.
                onChanged: denied
                    ? null
                    : (want) async {
                        final notifier = ref.read(
                          pushRegistrationProvider.notifier,
                        );
                        if (!want) {
                          await notifier.disable();
                          return;
                        }
                        final ok = await notifier.enable();
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showMasiToast(
                            "Couldn't turn on notifications for this device",
                            kind: MasiToastKind.error,
                          );
                        }
                      },
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown on iOS-in-Safari, where push is not merely unavailable but
/// unavailable *for a fixable reason*.
///
/// iOS grants Web Push only to a PWA that has been added to the home screen
/// (16.4+); a Safari tab receives nothing no matter what the user agrees to.
/// Rendering the generic "not supported" there would be true and useless —
/// this is one of the few cases where the user can actually do something.
class _IosInstallHint extends ConsumerWidget {
  const _IosInstallHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(pwaInstallStatusProvider);
    // Only on iOS, and only when NOT already installed. Anywhere else
    // "unsupported" really is the end of it, and a hint would be noise.
    if (install.platform != PwaPlatform.ios || install.isStandalone) {
      return const SizedBox.shrink();
    }

    final colors = MasiColors.of(context);
    return Padding(
      key: const Key('push-ios-install-hint'),
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.sm,
        MasiSpacing.lg,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(MasiSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(MasiRadii.card),
        ),
        child: Row(
          children: [
            MasiIcon('flash', size: 20, color: colors.ink3),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: Text(
                'To get alerts on this iPhone, add Masi to your Home Screen '
                'first — iOS only delivers notifications to the installed app.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
