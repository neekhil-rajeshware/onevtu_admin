/// Push for the review queue: a student lists something, whoever is on duty gets
/// told.
///
/// The counterpart of the seller's half. `notify-store` publishes to
/// [kTopicAdmins] when a listing arrives, and to the seller's own topic when this
/// app decides on it — so the two directions are one Edge Function and one topic
/// scheme, not two systems.
///
/// **[kTopicAdmins] is the third copy of a wire string.** It is spelled here, in
/// the student app's `lib/reminders/models/push_audience.dart`, and in
/// `supabase/functions/_shared/push_topics.ts`. Nothing checks that the three
/// agree, and they fail in the quietest possible way: the send succeeds, FCM
/// reports a message id, and no device is on the topic. Changing it means
/// changing all three.
///
/// **Taps do not come from Firebase here.** `notify-store` sends data-only
/// messages, on purpose — a `notification` block would have Android draw its own
/// notification whenever this app is backgrounded, on the wrong channel and with
/// a tap that opens the app and goes nowhere. The price is that
/// `FirebaseMessaging.getInitialMessage` and `onMessageOpenedApp` never fire,
/// because from Firebase's point of view no notification was ever shown. Every
/// tap arrives through flutter_local_notifications instead: [AdminPush._onTap]
/// while the app is alive, and [AdminPush.consumeLaunchTap] for a cold start.
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The topic every confirmed admin device subscribes to. See the note above
/// before touching this string.
const String kTopicAdmins = 'v1_admins';

/// The `data.channel` value `notify-store` marks a queue notice with.
///
/// Anything else — including no channel at all, which is what `send-push` sends —
/// is a student-facing announcement that reached this device by accident, and is
/// dropped rather than drawn.
const String kPushChannelStoreReview = 'store_review';

/// Android channel id. Persisted by the system along with whatever the admin
/// changes about it (sound, importance, whether it is blocked), so renaming this
/// silently creates a second channel and abandons those choices in the first.
const String _kChannelId = 'store_review_queue';
const String _kChannelName = 'Listings to review';
const String _kChannelDescription =
    'When a student lists something that needs approving.';

/// Notification ids live in one band so this app's own notices cannot collide
/// with anything else it may later show.
const int _kIdBase = 80000;

/// Prefix on the notification payload, carrying the listing id a tap should open.
const String _kPayloadPrefix = 'store_review:';

/// One queue notice, decided from a message's `data` before anything is drawn.
///
/// Split out from the drawing because every mistake in here is invisible on the
/// device: a message dropped by the channel gate looks exactly like a message that
/// never arrived, and an id that varies between deliveries looks exactly like two
/// students listing two things.
class QueueNotice {
  const QueueNotice({
    required this.notificationId,
    required this.title,
    required this.body,
    required this.listingId,
  });

  /// Reads one out of `RemoteMessage.data`, or null when this is not a queue
  /// notice and must not be drawn.
  ///
  /// The gate is `channel`. `send-push` sends student announcements with no
  /// channel at all, so anything unlabelled is something that reached this device
  /// by accident — subscribed to a cohort topic by an earlier build, say — and
  /// redrawing it here would put a student's circular on an admin's phone.
  static QueueNotice? fromData(Map<String, dynamic> data) {
    if (_text(data['channel']) != kPushChannelStoreReview) return null;

    final title = _text(data['title']);
    return QueueNotice(
      notificationId: _notificationId(_text(data['id'])),
      // A notice with no words is still worth showing: something is waiting, and
      // the queue is one tap away. Silence would be the worse failure.
      title: title.isEmpty ? 'New listing to review' : title,
      body: _text(data['body']),
      listingId: _text(data['listingId']),
    );
  }

  final int notificationId;
  final String title;
  final String body;
  final String listingId;

  /// What a tap carries back. Read by [listingIdFromPayload].
  String get payload => '$_kPayloadPrefix$listingId';

  /// Derived from the message id rather than incremented, so FCM's at-least-once
  /// delivery replaces the entry in the shade instead of stacking a second copy of
  /// it. That is also why this needs no "already seen" store: one listing is one id
  /// is one notification, however many times it arrives.
  ///
  /// `notify-store` builds those ids as `store-new-<row id>` and
  /// `store-review-<row id>-<reviewed_at>`, so a re-review of the same listing is
  /// deliberately a *different* notice — a second verdict is news.
  static int _notificationId(String messageId) =>
      _kIdBase + (messageId.isEmpty ? 0 : messageId.hashCode.abs() % 10000);

  static String _text(Object? value) => value?.toString().trim() ?? '';
}

/// The listing a tapped notice named, or null when the payload is not one of ours.
///
/// Empty string is a real answer: the notice was ours and named no listing.
String? listingIdFromPayload(String? payload) {
  if (payload == null || !payload.startsWith(_kPayloadPrefix)) return null;
  return payload.substring(_kPayloadPrefix.length);
}

/// Draws one queue notice. Top-level because the background isolate has no
/// [AdminPush] instance to reach — it is a fresh isolate with nothing but this
/// library's top-level state.
Future<void> _showQueueNotice(
  FlutterLocalNotificationsPlugin plugin,
  RemoteMessage message,
) async {
  final notice = QueueNotice.fromData(message.data);
  if (notice == null) {
    debugPrint('AdminPush: ignoring a message that is not a queue notice');
    return;
  }

  await plugin.show(
    notice.notificationId,
    notice.title,
    notice.body.isEmpty ? null : notice.body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        _kChannelName,
        channelDescription: _kChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: notice.payload,
  );
}

/// Runs in its own isolate when a message lands while the app is backgrounded or
/// dead, so it has to set Firebase and the plugin up again from nothing.
///
/// Must stay a top-level function with this annotation: the entry point is looked
/// up by name in a release build, and tree-shaking would otherwise remove it.
@pragma('vm:entry-point')
Future<void> adminPushBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final plugin = FlutterLocalNotificationsPlugin();
  // No tap callback: this isolate is gone by the time anyone taps. The tap is
  // picked up by the main isolate through `consumeLaunchTap`.
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await _showQueueNotice(plugin, message);
}

/// Sets push up and keeps the subscription in step with who is signed in.
///
/// Deliberately not a [ChangeNotifier]: nothing in the UI renders from this, and
/// the one thing it does that the UI cares about — opening the queue — is the
/// [onOpenReviewQueue] callback.
class AdminPush {
  AdminPush({required this.onOpenReviewQueue});

  /// Called with the listing id a tapped notice named, empty when it named none.
  /// Wired in `main.dart`, which is the only place that knows about screens.
  final void Function(String listingId) onOpenReviewQueue;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  AndroidFlutterLocalNotificationsPlugin? _android;

  bool _started = false;
  bool? _subscribed;

  /// Whether the last [syncSubscription] left this device on the admin topic.
  /// Null until one has run.
  bool? get subscribed => _subscribed;

  /// One-time setup: Firebase, the channel, and the handlers.
  ///
  /// Never throws. A phone with Play Services missing or notifications refused
  /// still has a perfectly working admin app — the queue is a screen, and the
  /// push is the convenience of not having to go and look at it.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await Firebase.initializeApp();

      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: _onTap,
      );

      _android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Created up front rather than on the first notification, so the admin can
      // find it in system settings before one has ever arrived.
      await _android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _kChannelId,
          _kChannelName,
          description: _kChannelDescription,
          importance: Importance.high,
        ),
      );

      FirebaseMessaging.onBackgroundMessage(adminPushBackgroundHandler);
      FirebaseMessaging.onMessage
          .listen((message) => _showQueueNotice(_plugin, message));
    } catch (error) {
      debugPrint('AdminPush.start failed: $error');
    }
  }

  /// Subscribes to [kTopicAdmins] when [isAdmin], unsubscribes when not.
  ///
  /// [isAdmin] must be `is_web_admin()`'s answer and nothing weaker — a
  /// password-only session is not it. Someone who cannot approve a listing should
  /// not be buzzed about one, and the second factor is exactly what separates
  /// "typed the right password" from "is on duty".
  ///
  /// A no-op when the state has not changed, so an auth event storm does not
  /// become a burst of FCM calls.
  Future<void> syncSubscription({required bool isAdmin}) async {
    if (!_started) return;
    if (_subscribed == isAdmin) return;
    try {
      if (isAdmin) {
        // Asked for here rather than at launch: Android 13+ shows nothing without
        // it, and this is the first moment it means anything. Someone who turns
        // out not to be an admin is never asked, and the admin is asked when the
        // app has just become able to explain why.
        await _android?.requestNotificationsPermission();
        await FirebaseMessaging.instance.subscribeToTopic(kTopicAdmins);
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic(kTopicAdmins);
      }
      _subscribed = isAdmin;
    } catch (error) {
      // Left unrecorded on purpose, so the next auth event retries. The failure
      // that matters is an unsubscribe that did not land — a phone that keeps
      // getting the queue after someone signed out of it — and retrying is the
      // only thing this app can do about that.
      debugPrint('AdminPush.syncSubscription($isAdmin) failed: $error');
    }
  }

  /// The tap that launched the app, if a notification did.
  ///
  /// Separate from [_onTap] because the launch tap has already happened by the
  /// time anything is listening: it is waiting to be collected rather than
  /// delivered. Safe to call once the first screen is up — calling it before
  /// there is a navigator would route into nothing.
  Future<void> consumeLaunchTap() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return;
      _route(details!.notificationResponse?.payload);
    } catch (error) {
      debugPrint('AdminPush.consumeLaunchTap failed: $error');
    }
  }

  void _onTap(NotificationResponse response) => _route(response.payload);

  void _route(String? payload) {
    final listingId = listingIdFromPayload(payload);
    if (listingId == null) return;
    onOpenReviewQueue(listingId);
  }
}
