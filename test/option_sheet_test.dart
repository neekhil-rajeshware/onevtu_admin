import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/ui/widgets/field_editor.dart';

/// The sheet every dropdown in the app opens. Worth a test because its failures
/// are quiet ones: an empty list and an unreachable list look identical on a
/// phone, and a column that accepts free text has nowhere else to type it.
Future<String?> _pick(
  WidgetTester tester, {
  required List<LookupOption> options,
  bool allowFreeText = false,
}) async {
  String? picked;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await chooseOption(
              context,
              title: 'Branch',
              options: options,
              allowFreeText: allowFreeText,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  const twoBranches = [LookupOption('CS'), LookupOption('CV')];

  testWidgets('a free-text column offers whatever was typed', (tester) async {
    await _pick(tester, options: twoBranches, allowFreeText: true);

    await tester.enterText(find.byType(TextField).last, 'AIML');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use "AIML"'));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget, reason: 'the sheet should close');
  });

  testWidgets('typing an existing value picks it rather than duplicating it',
      (tester) async {
    await _pick(tester, options: twoBranches, allowFreeText: true);

    await tester.enterText(find.byType(TextField).last, 'CV');
    await tester.pumpAndSettle();

    expect(find.text('Use "CV"'), findsNothing);
    // Matched on the tile, not with find.text: the search box holds "CV" too.
    expect(find.widgetWithText(ListTile, 'CV'), findsOneWidget);
  });

  testWidgets('a short pick-only list needs no search box', (tester) async {
    await _pick(tester, options: twoBranches);

    expect(find.byType(TextField), findsNothing);
    expect(find.text('CS'), findsOneWidget);
  });

  testWidgets('nothing to choose from says so', (tester) async {
    await _pick(tester, options: const []);

    expect(find.textContaining('no rows yet'), findsOneWidget);
  });

  testWidgets('a search that matches nothing names the search', (tester) async {
    await _pick(tester, options: twoBranches, allowFreeText: true);

    await tester.enterText(find.byType(TextField).last, 'zzz');
    await tester.pumpAndSettle();

    // Free text is allowed here, so the typed value is the offer — the
    // no-match message belongs to pick-only lists.
    expect(find.text('Use "zzz"'), findsOneWidget);
  });
}
