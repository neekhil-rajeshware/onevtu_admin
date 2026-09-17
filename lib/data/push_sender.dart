import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends one announcement to phones, through the `send-push` Edge Function.
///
/// The function is called rather than FCM directly because the FCM service
/// account must not live on a phone. It sits in Supabase as a secret, and this
/// app authorizes the send with nothing but the admin's own session — the same
/// JWT, and the same `is_web_admin()` check, as every other write here. That is
/// what keeps the APK free of any credential worth stealing.
///
/// The audience is deliberately never passed. The function reads it off the row
/// itself, so what lands on a phone always matches what the app's Circulars
/// screen shows for that announcement.
class PushSender {
  PushSender(this._client);

  final SupabaseClient _client;

  /// Who this announcement would reach, without sending anything.
  Future<PushPreview> preview(String id) async =>
      PushPreview.fromData(await _invoke(id, dryRun: true));

  /// Publishes it. Cannot be undone once FCM accepts it.
  Future<PushOutcome> send(String id) async =>
      PushOutcome.fromData(await _invoke(id, dryRun: false));

  Future<Map<String, dynamic>> _invoke(
    String id, {
    required bool dryRun,
  }) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'send-push',
        body: {'id': id, 'dryRun': dryRun},
      );
    } on FunctionException catch (error) {
      throw PushException(describePushFailure(error), status: error.status);
    }

    final data = response.data;
    if (data is! Map) {
      throw PushException('The function replied with something unexpected.');
    }
    final body = data.cast<String, dynamic>();
    // Every refusal the function makes carries its own status code, so this
    // should not fire — but the body is the authority on whether it worked, and
    // a 200 that says `ok: false` must not be read as a send.
    if (body['ok'] == false) {
      throw PushException(_errorText(body) ?? 'The function refused this.');
    }
    return body;
  }
}

/// What a dry run says about one announcement.
class PushPreview {
  const PushPreview({
    required this.topic,
    required this.topics,
    required this.alreadySent,
    required this.secretConfigured,
  });

  factory PushPreview.fromData(Map<String, dynamic> data) => PushPreview(
        topic: data['topic']?.toString() ?? '',
        topics: _stringList(data['topics']),
        alreadySent: data['alreadySent'] == true,
        // Absent means an older deployment of the function that does not report
        // it. Treated as configured: a send that would have worked must not be
        // blocked by a field the function never sent.
        secretConfigured: data['secretConfigured'] != false,
      );

  /// The canonical audience topic — the one recorded on the row.
  final String topic;

  /// Every topic the send would publish to. More than one only while installs
  /// subscribed under an older spelling of the scheme are still out there.
  final List<String> topics;

  /// True when this row has been pushed before, so sending buzzes everyone a
  /// second time.
  final bool alreadySent;

  /// False when Supabase has no `FCM_SERVICE_ACCOUNT` secret, which a real send
  /// would fail on.
  final bool secretConfigured;

  /// The extra spellings beyond the canonical topic, for the confirmation.
  int get olderSpellings => topics.length <= 1 ? 0 : topics.length - 1;
}

/// What a real send did. FCM reports nothing about how many devices it reached,
/// so this means "published", never "delivered".
class PushOutcome {
  const PushOutcome({
    required this.topic,
    required this.topics,
    this.messageName,
  });

  factory PushOutcome.fromData(Map<String, dynamic> data) => PushOutcome(
        topic: data['topic']?.toString() ?? '',
        topics: _stringList(data['topics']),
        messageName: data['messageName']?.toString(),
      );

  final String topic;

  /// The topics that were actually accepted.
  final List<String> topics;

  /// FCM's own name for the message, when it gave one.
  final String? messageName;
}

/// A send, or the check before it, that did not happen — carrying the Edge
/// Function's own words rather than a status code.
class PushException implements Exception {
  PushException(this.message, {this.status});

  final String message;

  /// HTTP status the function replied with; 0 when the request never landed.
  final int? status;

  @override
  String toString() => message;
}

/// The function's own explanation of a failure.
///
/// Worth its own function because the status code alone is useless here: "not an
/// admin", "the FCM secret is missing", "that row is gone" and "push is off on
/// this row" all arrive as one non-2xx, and the sentence that tells them apart is
/// in the response body. The Dart client keeps that body, already decoded, on
/// [FunctionException.details] — so unlike the website (where supabase-js throws
/// the body away and it has to be re-read off the raw `Response`) there is
/// nothing to dig out but this field.
String describePushFailure(FunctionException error) {
  // A request that never landed has an exception object in `details`, not the
  // function's words, so it is answered before anything is read out of there.
  if (error is FunctionsFetchException) {
    return 'Could not reach Supabase. Check the connection and try again.';
  }

  final details = error.details;
  if (details is Map) {
    final text = _errorText(details.cast<String, dynamic>());
    if (text != null) return text;
  }
  if (details is String && details.trim().isNotEmpty) {
    return details.trim();
  }

  final reason = error.reasonPhrase?.trim();
  return (reason == null || reason.isEmpty)
      ? 'The function failed with status ${error.status}.'
      : '$reason (${error.status})';
}

/// Plain-English audience, for the confirmation. Read off the same three columns
/// the function reads, so the prompt cannot describe a different audience than
/// the one that gets the push.
String describePushAudience(Map<String, dynamic> row) {
  final parts = <String>[];
  final branch = row['branch_code']?.toString().trim() ?? '';
  final scheme = row['scheme_code']?.toString().trim() ?? '';
  final semester = row['semester']?.toString().trim() ?? '';
  if (branch.isNotEmpty) parts.add(branch);
  if (scheme.isNotEmpty) parts.add('$scheme scheme');
  if (semester.isNotEmpty) parts.add('semester $semester');
  return parts.isEmpty ? 'every student' : '${parts.join(', ')} students';
}

String? _errorText(Map<String, dynamic> body) {
  final error = body['error'];
  if (error == null) return null;
  final text = error.toString().trim();
  return text.isEmpty ? null : text;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((v) => v?.toString() ?? '')
      .where((v) => v.isNotEmpty)
      .toList(growable: false);
}
