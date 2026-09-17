import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/ui/widgets/moderation_action.dart';

/// The approval queue's two buttons. Worth testing without a database because
/// every mistake here is one an admin cannot see: an Approve offered on a row
/// that is already live publishes nothing and looks broken, and a Take-down
/// offered on a rejected row only re-asks for a reason that is already stored.
///
/// None of these taps reaches a write, so no repository is provided — a
/// regression that wrote on Cancel would fail with a missing provider rather
/// than pass quietly.
void main() {
  final spec = specForTable('store')!;

  Future<void> pumpRow(WidgetTester tester, Map<String, dynamic> row) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ModerationAction(spec: spec, row: row)),
    ));
  }

  group('what is on offer', () {
    testWidgets('a waiting listing can go either way', (tester) async {
      await pumpRow(tester, {'id': 'a', 'status': 'pending', 'title': 'Tables'});

      expect(find.byTooltip('Approve'), findsOneWidget);
      expect(find.byTooltip('Not approved'), findsOneWidget);
    });

    testWidgets('a live listing can only be taken down', (tester) async {
      await pumpRow(tester, {'id': 'a', 'status': 'approved'});

      expect(find.byTooltip('Approve'), findsNothing);
      expect(find.byTooltip('Take it down'), findsOneWidget);
    });

    testWidgets('a turned-down listing can only be let through', (tester) async {
      await pumpRow(tester, {'id': 'a', 'status': 'rejected'});

      expect(find.byTooltip('Approve after all'), findsOneWidget);
      expect(find.byTooltip('Not approved'), findsNothing);
      expect(find.byTooltip('Take it down'), findsNothing);
    });

    testWidgets('a row with no status yet is treated as waiting',
        (tester) async {
      // `status` is NOT NULL in the table, so this is the unsaved-row case and
      // the safe reading of it is "not published".
      await pumpRow(tester, {'id': 'a'});

      expect(find.byTooltip('Approve'), findsOneWidget);
      expect(find.byTooltip('Not approved'), findsOneWidget);
    });

    testWidgets('a row with no id at all offers nothing', (tester) async {
      await pumpRow(tester, {'status': 'pending'});

      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('approving', () {
    testWidgets('names the listing and says it goes public', (tester) async {
      await pumpRow(tester, {
        'id': 'a',
        'status': 'pending',
        'title': 'Engineering Maths',
        'price': '250',
        'seller_name': 'Asha',
      });

      await tester.tap(find.byTooltip('Approve'));
      await tester.pumpAndSettle();

      // The summary is the only guard against a mis-tap in a list of rows that
      // all look alike at a glance.
      expect(
        find.textContaining('“Engineering Maths” · ₹250 from Asha'),
        findsOneWidget,
      );
      expect(find.textContaining('every student'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsNothing, reason: 'dialog should close');
    });
  });

  group('turning down', () {
    testWidgets('offers a reason, and a preset fills it in', (tester) async {
      await pumpRow(tester, {'id': 'a', 'status': 'pending', 'title': 'Kit'});

      await tester.tap(find.byTooltip('Not approved'));
      await tester.pumpAndSettle();

      expect(find.text('Not approved?'), findsOneWidget);
      await tester.tap(find.text('Photo needed'));
      await tester.pumpAndSettle();

      // The seller reads the sentence, not the chip's label.
      expect(
        find.text('Add a clear photo of the item you are selling.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Turn down'), findsNothing);
    });

    testWidgets('a live listing is worded as coming down', (tester) async {
      await pumpRow(tester, {'id': 'a', 'status': 'approved', 'title': 'Kit'});

      await tester.tap(find.byTooltip('Take it down'));
      await tester.pumpAndSettle();

      expect(find.text('Take this down?'), findsOneWidget);
      expect(find.textContaining('comes off the Store'), findsOneWidget);
    });

    testWidgets('the reason cannot outrun the column', (tester) async {
      // store_review_note_length caps it at 500; a note refused by the database
      // would lose the whole decision, not just the wording.
      await pumpRow(tester, {'id': 'a', 'status': 'pending'});

      await tester.tap(find.byTooltip('Not approved'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLength, 500);
    });
  });
}
