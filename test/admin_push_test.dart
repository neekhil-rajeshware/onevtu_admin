import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/core/admin_push.dart';

/// The decisions taken before a queue notice is drawn.
///
/// Worth testing without a device because every mistake in here is invisible on
/// one. A notice the gate drops looks exactly like a notice that never arrived; an
/// id that changes between two deliveries of the same message looks exactly like
/// two students listing two things; and a payload that does not round-trip looks
/// exactly like a notification that opens nothing.
///
/// The fixtures are the real `data` maps `supabase/functions/notify-store` builds,
/// copied key for key. A test written against invented keys would pass while the
/// app ignored every real message.
void main() {
  /// What `notify-store` sends to `v1_admins` when a student lists something.
  Map<String, dynamic> submitted({
    String id = 'store-new-7f3c9e2a',
    String title = 'New listing to review',
    String body = 'Engineering Maths — ₹250 · Books',
    String listingId = '7f3c9e2a',
  }) =>
      {
        'id': id,
        'title': title,
        'body': body,
        'channel': 'store_review',
        'listingId': listingId,
      };

  /// What it sends to the seller's own topic once this app decides. It reaches an
  /// admin's phone only if the admin also sells things — but this app must not
  /// draw it either way.
  Map<String, dynamic> reviewed() => {
        'id': 'store-review-7f3c9e2a-2026-08-31T09:00:00Z',
        'title': 'Your listing is live',
        'body': '“Engineering Maths” is now on the Store.',
        'channel': 'store_listing',
        'listingId': '7f3c9e2a',
        'userId': 'a1b2c3',
      };

  group('what gets drawn', () {
    test('a new listing does', () {
      final notice = QueueNotice.fromData(submitted());

      expect(notice, isNotNull);
      expect(notice!.title, 'New listing to review');
      expect(notice.body, 'Engineering Maths — ₹250 · Books');
      expect(notice.listingId, '7f3c9e2a');
    });

    test('a seller-facing verdict does not', () {
      // The student app draws this one. An admin who also sells things is
      // subscribed to both topics, and seeing "Your listing is live" on the admin
      // console would be someone else's app talking.
      expect(QueueNotice.fromData(reviewed()), isNull);
    });

    test('an announcement does not', () {
      // `send-push` sends student circulars with no channel key at all. Anything
      // unlabelled reached this device by accident and is not ours to redraw.
      expect(
        QueueNotice.fromData({
          'id': 'announcement-12',
          'title': 'Exam timetable is out',
          'body': 'Check the Circulars screen.',
        }),
        isNull,
      );
    });

    test('a channel this app does not know does not', () {
      expect(QueueNotice.fromData(submitted()..['channel'] = 'store_reviews'),
          isNull);
    });

    test('a notice with no words still does', () {
      // Something is waiting and the queue is one tap away. Silence would be the
      // worse failure of the two.
      final notice = QueueNotice.fromData({'channel': 'store_review'});

      expect(notice, isNotNull);
      expect(notice!.title, 'New listing to review');
      expect(notice.body, isEmpty);
    });

    test('padding around the values is not part of them', () {
      final notice = QueueNotice.fromData({
        'channel': '  store_review  ',
        'title': '  New listing  ',
        'listingId': ' 7f3c9e2a ',
      });

      expect(notice, isNotNull);
      expect(notice!.title, 'New listing');
      expect(notice.listingId, '7f3c9e2a');
    });
  });

  group('the notification id', () {
    test('is the same every time the same message arrives', () {
      // FCM delivers at least once. A second delivery must replace the entry in
      // the shade, not add to it.
      final first = QueueNotice.fromData(submitted())!;
      final again = QueueNotice.fromData(submitted())!;

      expect(again.notificationId, first.notificationId);
    });

    test('differs between two listings', () {
      final a = QueueNotice.fromData(submitted(id: 'store-new-aaa'))!;
      final b = QueueNotice.fromData(submitted(id: 'store-new-bbb'))!;

      expect(a.notificationId, isNot(b.notificationId));
    });

    test('stays inside this app own band', () {
      for (final id in ['', 'store-new-a', 'store-new-zzzzzzzzzzzzzzzzzzzz']) {
        final notice = QueueNotice.fromData(submitted(id: id))!;
        expect(notice.notificationId, inInclusiveRange(80000, 89999));
      }
    });
  });

  group('what a tap carries', () {
    test('round-trips the listing', () {
      final notice = QueueNotice.fromData(submitted(listingId: 'abc'))!;

      expect(listingIdFromPayload(notice.payload), 'abc');
    });

    test('a notice that named no listing still routes', () {
      // The destination is the queue, not the row, so an empty id is a usable
      // answer and must not be confused with "not one of ours".
      final notice = QueueNotice.fromData({'channel': 'store_review'})!;

      expect(listingIdFromPayload(notice.payload), '');
    });

    test('something else entirely does not route', () {
      expect(listingIdFromPayload(null), isNull);
      expect(listingIdFromPayload(''), isNull);
      expect(listingIdFromPayload('abc'), isNull);
      // The student app's own payload shape, in case the two ever get crossed.
      expect(listingIdFromPayload('route:/my-listings|abc'), isNull);
    });
  });

  group('the wire strings', () {
    test('are what the other two copies spell', () {
      // Pinned rather than derived, because they cannot be derived: the same two
      // strings are written out again in the student app's
      // `lib/reminders/models/push_audience.dart` and in
      // `supabase/functions/_shared/push_topics.ts`. A one-character difference
      // makes the send succeed and reach nobody, so changing either of these
      // means changing all three.
      expect(kTopicAdmins, 'v1_admins');
      expect(kPushChannelStoreReview, 'store_review');
    });
  });
}
