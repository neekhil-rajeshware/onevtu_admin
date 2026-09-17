import 'package:supabase_flutter/supabase_flutter.dart';

import 'push_sender.dart';

/// Tells a seller what was decided about their listing, through the
/// `notify-store` Edge Function.
///
/// Same shape and same reasoning as [PushSender]: the FCM service account stays a
/// Supabase secret, this app authorizes the send with nothing but the admin's own
/// session, and `notify-store` re-checks `is_web_admin()` before it publishes —
/// so an APK that leaks tells an attacker nothing they could send with.
///
/// Reuses [PushException] and [describePushFailure] rather than restating them.
/// The two functions fail in the same ways, and a second copy of that translation
/// would only be a second copy to keep correct.
///
/// The message itself is never passed. The function reads the row and writes the
/// wording off `status`, which is why a seller can never be told they were
/// approved by a call that actually rejected them.
class StoreNotifier {
  StoreNotifier(this._client);

  final SupabaseClient _client;

  /// Pushes the verdict to whoever listed [listingId].
  ///
  /// Call this *after* the status write has landed, never before: the function
  /// reads `status` back off the row to decide the wording, so calling it first
  /// would notify the seller of the previous decision.
  ///
  /// Throws [PushException] when the seller was not told. The caller has already
  /// changed the listing by then, so this is never a reason to undo anything —
  /// only a reason to say so.
  Future<void> notifySeller(String listingId) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'notify-store',
        body: {'listingId': listingId, 'event': 'reviewed'},
      );
    } on FunctionException catch (error) {
      throw PushException(describePushFailure(error), status: error.status);
    }

    final data = response.data;
    // A 2xx with no body would mean the publish never got as far as FCM.
    if (data is! Map || data['ok'] == false) {
      throw PushException('The seller may not have been notified.');
    }
  }
}
