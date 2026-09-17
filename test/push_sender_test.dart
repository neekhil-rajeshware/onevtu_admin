import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/data/push_sender.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/schema/field_spec.dart';
import 'package:onevtu_admin/ui/widgets/push_action.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('describePushFailure', () {
    test("uses the function's own sentence, not the status code", () {
      // Every refusal send-push makes arrives as a non-2xx with the reason in
      // the body. Losing that turns four different problems into one shrug.
      for (final failure in [
        (403, 'admin only'),
        (404, 'notification not found'),
        (409, 'push is disabled on this row'),
        (401, 'not signed in'),
      ]) {
        final error = FunctionsHttpException(
          status: failure.$1,
          details: {'ok': false, 'error': failure.$2},
          reasonPhrase: 'Bad Request',
        );
        expect(describePushFailure(error), failure.$2);
      }
    });

    test('the missing-secret instruction survives intact', () {
      const message =
          'FCM_SERVICE_ACCOUNT secret is not set. Add it in Supabase '
          '(Edge Functions -> Secrets) with the JSON from Firebase Console.';
      final error = FunctionsHttpException(
        status: 500,
        details: const {'ok': false, 'error': message},
      );
      expect(describePushFailure(error), message);
    });

    test('a body that is not JSON still reaches the screen', () {
      final error = FunctionsHttpException(
        status: 502,
        details: 'Bad Gateway from the edge runtime',
      );
      expect(describePushFailure(error), 'Bad Gateway from the edge runtime');
    });

    test('a request that never landed says so, not what the socket said', () {
      final error = FunctionsFetchException(
        details: Exception('SocketException: Failed host lookup'),
      );
      expect(describePushFailure(error), contains('Could not reach Supabase'));
    });

    test('falls back to the status when there is nothing else', () {
      expect(
        describePushFailure(const FunctionsHttpException(status: 500)),
        contains('500'),
      );
      expect(
        describePushFailure(const FunctionsHttpException(
          status: 503,
          reasonPhrase: 'Service Unavailable',
        )),
        'Service Unavailable (503)',
      );
    });
  });

  group('PushPreview', () {
    test('reads a dry run', () {
      final preview = PushPreview.fromData(const {
        'ok': true,
        'topic': 'v1_b-CSE.s-3.m-5',
        'topics': ['v1_b-CSE.s-3.m-5', 'v1_b-CSE.s-2018.m-5'],
        'dryRun': true,
        'alreadySent': true,
        'secretConfigured': true,
      });
      expect(preview.topic, 'v1_b-CSE.s-3.m-5');
      expect(preview.topics, hasLength(2));
      expect(preview.olderSpellings, 1);
      expect(preview.alreadySent, isTrue);
      expect(preview.secretConfigured, isTrue);
    });

    test('a missing secret is reported, not assumed', () {
      final preview = PushPreview.fromData(const {
        'ok': true,
        'topic': 'v1_all',
        'topics': ['v1_all'],
        'secretConfigured': false,
      });
      expect(preview.secretConfigured, isFalse);
      expect(preview.olderSpellings, 0);
    });

    test('an older deployment that reports nothing does not block a send', () {
      // `secretConfigured` was added to the function after the first version.
      // Absent has to mean "go ahead", or the app refuses a send that works.
      expect(PushPreview.fromData(const {'ok': true}).secretConfigured, isTrue);
      expect(PushPreview.fromData(const {'ok': true}).alreadySent, isFalse);
      expect(PushPreview.fromData(const {'ok': true}).topics, isEmpty);
    });
  });

  group('describePushAudience', () {
    test('no audience columns means everyone', () {
      expect(describePushAudience(const {}), 'every student');
      expect(
        describePushAudience(const {
          'branch_code': '',
          'scheme_code': null,
          'semester': null,
        }),
        'every student',
      );
    });

    test('reads the same three columns the function does', () {
      expect(
        describePushAudience(const {
          'branch_code': 'Computer Science and Engineering',
          'scheme_code': '3',
          'semester': 5,
        }),
        'Computer Science and Engineering, 3 scheme, semester 5 students',
      );
      expect(
        describePushAudience(const {'semester': 1}),
        'semester 1 students',
      );
    });
  });

  group('PushOutcome', () {
    test('keeps the topics that were accepted', () {
      final outcome = PushOutcome.fromData(const {
        'ok': true,
        'topic': 'v1_all',
        'topics': ['v1_all'],
        'messageName': 'projects/x/messages/123',
      });
      expect(outcome.topic, 'v1_all');
      expect(outcome.topics, ['v1_all']);
      expect(outcome.messageName, 'projects/x/messages/123');
    });
  });

  group('catalog', () {
    test('only announcements can send a push, and expose what it recorded', () {
      final sendable =
          adminCatalog.where((s) => s.canSendPush).map((s) => s.table);
      expect(sendable, ['notifications']);

      final spec = specForTable('notifications')!;
      // The send button reads these off the row, and the editor shows the last
      // two after a send.
      for (final column in [
        'id',
        'push_enabled',
        'push_sent_at',
        'push_topic',
        'push_error',
      ]) {
        expect(spec.fieldFor(column), isNotNull, reason: column);
      }
      // The outcome columns are written by the function, never by the form.
      for (final column in ['push_sent_at', 'push_topic', 'push_error']) {
        expect(spec.fieldFor(column)!.readOnly, isTrue, reason: column);
      }
    });

    test('a new announcement starts with sending allowed, as the column does',
        () {
      // Otherwise the switch reads off while `push_enabled` defaults to true,
      // and a row whose toggle looked off still gets a send button.
      final spec = specForTable('notifications')!;
      expect(spec.fieldFor('push_enabled')!.defaultValue, 'true');
      expect(spec.fieldFor('is_active')!.defaultValue, 'true');
    });

    test('every default is in the form\'s own spelling of that type', () {
      for (final spec in adminCatalog) {
        for (final field in spec.fields) {
          final value = field.defaultValue;
          if (value == null) continue;
          expect(field.readOnly, isFalse,
              reason: '${spec.table}.${field.column} is read-only');
          if (field.type == FieldType.boolean) {
            expect(value, anyOf('true', 'false'),
                reason: '${spec.table}.${field.column}');
          }
          expect(FieldCodec.validate(field, value), isNull,
              reason: '${spec.table}.${field.column}');
        }
      }
    });
  });

  group('PushSendButton', () {
    // Neither of these taps, so no PushSender is needed: what is being checked
    // is that the row alone decides whether sending is on offer.
    testWidgets('is absent when push is turned off on the row', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PushSendButton(row: {'id': 'a', 'push_enabled': false}),
        ),
      ));
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('offers a send, and says when it is a second one',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: PushSendButton(row: {'id': 'a'})),
      ));
      expect(find.byTooltip('Send to phones'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PushSendButton(
            row: {'id': 'a', 'push_sent_at': '2026-08-30T10:00:00Z'},
          ),
        ),
      ));
      expect(find.byTooltip('Sent already — send again'), findsOneWidget);
    });
  });
}
