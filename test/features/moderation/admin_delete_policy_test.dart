// Who may delete what, as a pure function (`lib/features/moderation/domain/
// admin_delete_policy.dart`). Import-free by design, so this file needs
// neither a ProviderContainer nor a widget tree — just the truth table.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/domain/admin_delete_policy.dart';

void main() {
  group('adminContentAction', () {
    test(
      'not signed in hides the control even when isAdmin is true — the two '
      'gates are independent, so a hand-built isAdmin:true in a test must not '
      'alone be enough to show a destructive control',
      () {
        expect(
          adminContentAction(isAdmin: true, isSignedIn: false),
          AdminContentAction.hidden,
        );
      },
    );

    test('signed in but not an admin hides the control', () {
      expect(
        adminContentAction(isAdmin: false, isSignedIn: true),
        AdminContentAction.hidden,
      );
    });

    test(
      'neither signed in nor an admin hides the control (both gates failing '
      'at once is still just hidden, not some other state)',
      () {
        expect(
          adminContentAction(isAdmin: false, isSignedIn: false),
          AdminContentAction.hidden,
        );
      },
    );

    test('an admin, signed in, looking at live content is offered delete', () {
      expect(
        adminContentAction(isAdmin: true, isSignedIn: true),
        AdminContentAction.delete,
      );
    });

    test(
      'an admin looking at deleted, restorable content is offered restore, '
      'not delete',
      () {
        expect(
          adminContentAction(
            isAdmin: true,
            isSignedIn: true,
            isDeleted: true,
            isRestorable: true,
          ),
          AdminContentAction.restore,
        );
      },
    );

    test(
      'an admin looking at deleted content that is NOT restorable gets '
      'nothing offered — NOT delete. Offering "Delete" for something already '
      'gone is how an admin taps twice, sees no change, and concludes the '
      'feature is broken',
      () {
        expect(
          adminContentAction(
            isAdmin: true,
            isSignedIn: true,
            isDeleted: true,
            isRestorable: false,
          ),
          AdminContentAction.hidden,
        );
      },
    );

    test(
      'isRestorable is irrelevant when the content is not deleted — it must '
      'not accidentally flip live content into restore',
      () {
        expect(
          adminContentAction(
            isAdmin: true,
            isSignedIn: true,
            isDeleted: false,
            isRestorable: true,
          ),
          AdminContentAction.delete,
        );
      },
    );

    test('a non-admin sees hidden regardless of deleted/restorable state', () {
      expect(
        adminContentAction(
          isAdmin: false,
          isSignedIn: true,
          isDeleted: true,
          isRestorable: true,
        ),
        AdminContentAction.hidden,
      );
    });
  });

  group('isForeignContent', () {
    test(
      'a null ownerId is treated as foreign — an unknown owner is the '
      'conservative case, so the louder confirmation wins',
      () {
        expect(
          isForeignContent(ownerId: null, viewerUid: 'me'),
          isTrue,
        );
      },
    );

    test(
      'a null viewerUid is treated as foreign — a signed-out (or unresolved) '
      'viewer can never claim content as their own',
      () {
        expect(
          isForeignContent(ownerId: 'owner-1', viewerUid: null),
          isTrue,
        );
      },
    );

    test('both ids null is still foreign', () {
      expect(isForeignContent(ownerId: null, viewerUid: null), isTrue);
    });

    test('equal ids are NOT foreign — an admin acting on their own content', () {
      expect(
        isForeignContent(ownerId: 'same-uid', viewerUid: 'same-uid'),
        isFalse,
      );
    });

    test('different ids are foreign', () {
      expect(
        isForeignContent(ownerId: 'owner-1', viewerUid: 'admin-2'),
        isTrue,
      );
    });
  });
}
