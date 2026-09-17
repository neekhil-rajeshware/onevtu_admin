import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/data/lookup_cache.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/schema/field_spec.dart';
import 'package:onevtu_admin/ui/widgets/field_editor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every field of every table, drawn once.
///
/// This app has no per-table screens — one [FieldEditor] renders seventeen
/// tables' worth of columns — so a field type that cannot be built is not one
/// broken screen, it is every screen that uses it, on the first frame. That is
/// exactly what happened: `documentList` was given a hard-coded `minLines` of 3
/// against `FieldSpec.maxLines`'s default of 1, and `TextFormField` asserts on
/// that rather than clamping, so opening any subject took the editor down.
///
/// Nothing here is about looks. It is a smoke test over the catalog: draw one of
/// everything, and fail naming the column that could not be drawn.
void main() {
  // Never queried — a dropdown only reads its lookup when it is tapped, and
  // nothing in this file taps. The client is here because `LookupCache` has to
  // be handed one, and building one issues no request.
  final lookups = LookupCache(
    AdminRepository(SupabaseClient('http://localhost:54321', 'test-key')),
  );

  Widget harness(FieldSpec field) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FieldEditor(
                field: field,
                controller: TextEditingController(text: ''),
                lookups: lookups,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );

  testWidgets('every field in the catalog can be drawn', (tester) async {
    for (final spec in adminCatalog) {
      for (final field in spec.fields) {
        await tester.pumpWidget(harness(field));
        final thrown = tester.takeException();
        expect(
          thrown,
          isNull,
          reason: '${spec.table}.${field.column} (${field.type.name}) '
              'could not be drawn: $thrown',
        );
      }
    }
  });

  testWidgets('a field that leaves maxLines alone still draws', (tester) async {
    // The bug, in its smallest form: `FieldSpec.maxLines` defaults to 1 and
    // `documentList` wants a code box, so the two have to be reconciled rather
    // than handed to Flutter to argue about.
    const field =
        FieldSpec('notes_link', 'Notes', type: FieldType.documentList);
    expect(field.maxLines, 1);
    await tester.pumpWidget(harness(field));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tall box opens at three lines, never more than it may',
      (tester) async {
    // The other half of the fix: clamping must not collapse every code box to a
    // single line. Both of the catalog's document columns ask for eight.
    const tall = FieldSpec('notes_link', 'Notes',
        type: FieldType.documentList, maxLines: 8);
    await tester.pumpWidget(harness(tall));
    final box = tester.widget<TextField>(find.byType(TextField));
    expect(box.minLines, 3);
    expect(box.maxLines, 8);

    const ordinary = FieldSpec('title', 'Title', maxLines: 2);
    await tester.pumpWidget(harness(ordinary));
    final plain = tester.widget<TextField>(find.byType(TextField));
    expect(plain.minLines, 1);
    expect(plain.maxLines, 2);
  });

  testWidgets('no field asks for more lines than it allows', (tester) async {
    // The invariant the crash was a violation of, stated once over the whole
    // catalog — including any field type added after this was written.
    for (final spec in adminCatalog) {
      for (final field in spec.fields) {
        await tester.pumpWidget(harness(field));
        // Booleans, dates and dropdowns are not text boxes and have no lines to
        // disagree about.
        if (find.byType(TextField).evaluate().isEmpty) continue;
        final box = tester.widget<TextField>(find.byType(TextField));
        final minLines = box.minLines;
        final maxLines = box.maxLines;
        if (minLines == null || maxLines == null) continue;
        expect(
          minLines,
          lessThanOrEqualTo(maxLines),
          reason: '${spec.table}.${field.column} asks for minLines $minLines '
              'inside maxLines $maxLines',
        );
        expect(minLines, greaterThan(0));
      }
    }
  });
}
