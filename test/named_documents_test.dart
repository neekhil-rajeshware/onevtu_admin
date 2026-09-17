import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/r2/bucket_layout.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/schema/field_spec.dart';
import 'package:onevtu_admin/schema/named_documents.dart';
import 'package:onevtu_admin/schema/table_spec.dart';

void main() {
  group('parseNamedDocuments', () {
    test('reads the shape the picker writes, in order', () {
      final documents = parseNamedDocuments('''
[
  {"name": "Module 1", "link": "https://pub.r2.dev/m1.pdf"},
  {"name": "Module 2", "link": "https://pub.r2.dev/m2.pdf"}
]
''');

      expect(documents, hasLength(2));
      expect(documents[0].name, 'Module 1');
      expect(documents[0].url, 'https://pub.r2.dev/m1.pdf');
      expect(documents[1].name, 'Module 2');
    });

    test('reads a lone bare URL — the shape a cell had before the JSON', () {
      // A branch already carrying a hand-typed link must not lose it to this
      // change; it is exactly what `branches.id = 36` holds.
      final documents = parseNamedDocuments(
        'https://drive.google.com/file/d/abc/view',
        // What the record editor passes: the column's own label.
        fallbackName: 'Study materials',
      );

      expect(documents, hasLength(1));
      expect(documents.single.name, 'Study materials',
          reason: 'the fallback names an entry the cell left unnamed');
      expect(documents.single.url, 'https://drive.google.com/file/d/abc/view');
    });

    test('a single object reads as one document', () {
      final documents = parseNamedDocuments(
          '{"name": "Lab Record", "link": "https://pub.r2.dev/lab.pdf"}');

      expect(documents, hasLength(1));
      expect(documents.single.name, 'Lab Record');
    });

    test('a list of bare URLs numbers them by position', () {
      final documents = parseNamedDocuments(
        '["https://pub.r2.dev/a.pdf", "https://pub.r2.dev/b.pdf"]',
        fallbackName: 'Notes',
      );

      expect(documents.map((d) => d.name), ['Notes 1', 'Notes 2']);
    });

    test('key spelling is loose, and case and underscores do not matter', () {
      final documents = parseNamedDocuments(
          '[{"Title": "Unit 1", "URL": "https://pub.r2.dev/u1.pdf"}]');

      expect(documents.single.name, 'Unit 1');
      expect(documents.single.url, 'https://pub.r2.dev/u1.pdf');

      final alt = parseNamedDocuments(
          '[{"label": "Unit 2", "file_name": "", "href":'
          ' "https://pub.r2.dev/u2.pdf"}]');
      expect(alt.single.name, 'Unit 2');
      expect(alt.single.url, 'https://pub.r2.dev/u2.pdf');
    });

    test('a scheme-less host and path still reads', () {
      // Both editors share one rule with the student app's viewer, which opens
      // `drive.google.com/…` as happily as it opens `https://…`.
      final documents =
          parseNamedDocuments('[{"name": "Old", "link": "drive.google.com/f/d/1"}]');
      expect(documents.single.url, 'drive.google.com/f/d/1');
    });

    test('an entry that is not URL-shaped is dropped', () {
      // The whole reason the parser is defensive: without this, "waiting for the
      // key" became a live button that opened a blank page and got queued for
      // download by the app's indexer.
      final documents = parseNamedDocuments('''
[
  {"name": "Waiting for the key", "link": "waiting for the key"},
  {"name": "Real", "link": "https://pub.r2.dev/real.pdf"}
]
''');

      expect(documents, hasLength(1));
      expect(documents.single.name, 'Real');
    });

    test('nothing at all comes back for an empty or unreadable cell', () {
      expect(parseNamedDocuments(null), isEmpty);
      expect(parseNamedDocuments(''), isEmpty);
      expect(parseNamedDocuments('   '), isEmpty);
      expect(parseNamedDocuments('[not json'), isEmpty,
          reason: 'a half-written cell costs this row its files, not the table');
    });

    test('an already-decoded value reads too', () {
      // For the day either column becomes `jsonb`.
      expect(
        parseNamedDocuments([
          {'name': 'A', 'link': 'https://pub.r2.dev/a.pdf'},
        ]).single.name,
        'A',
      );
    });
  });

  group('encodeNamedDocuments', () {
    test('writes the shape the student app reads', () {
      final cell = encodeNamedDocuments(const [
        NamedDocument(name: 'Module 1', url: 'https://pub.r2.dev/m1.pdf'),
        NamedDocument(name: 'Module 2', url: 'https://pub.r2.dev/m2.pdf'),
      ]);

      expect(cell, contains('"name": "Module 1"'));
      expect(cell, contains('"link": "https://pub.r2.dev/m1.pdf"'));
      // Pretty-printed, because a person opens this column in a spreadsheet.
      expect(cell, contains('\n  '));
      expect(parseNamedDocuments(cell).map((d) => d.name),
          ['Module 1', 'Module 2']);
    });

    test('empty in, empty out', () {
      // An empty string clears the column. `[]` would read as a row with no
      // files to the app but as data to whoever opens the sheet next.
      expect(encodeNamedDocuments(const []), '');
    });

    test('a nameless entry is written without a name key', () {
      final cell = encodeNamedDocuments(
          const [NamedDocument(name: '  ', url: 'https://pub.r2.dev/a.pdf')]);
      expect(cell, isNot(contains('"name"')));
      // And it comes back named by position rather than blank.
      expect(parseNamedDocuments(cell, fallbackName: 'Notes').single.name,
          'Notes');
    });

    test('a round trip keeps order and names', () {
      const input = [
        NamedDocument(name: 'Handwritten', url: 'https://pub.r2.dev/h.pdf'),
        NamedDocument(name: 'Module 1', url: 'https://pub.r2.dev/m1.pdf'),
        NamedDocument(name: 'Module 2', url: 'https://pub.r2.dev/m2.pdf'),
      ];
      expect(parseNamedDocuments(encodeNamedDocuments(input)), input);
    });
  });

  group('guessDocumentName', () {
    test('drops the extension and opens the underscores out', () {
      expect(guessDocumentName('Module_1_Notes.pdf'), 'Module 1 Notes');
      expect(guessDocumentName('1BAE305 Introduction to UAV.pdf'),
          '1BAE305 Introduction to UAV');
    });

    test('keeps a hyphen, which somebody typed on purpose', () {
      expect(guessDocumentName('Unit-3 Notes.pdf'), 'Unit-3 Notes');
    });

    test('a name with no extension survives', () {
      expect(guessDocumentName('Handwritten'), 'Handwritten');
      // A leading dot is a hidden file, not an extension.
      expect(guessDocumentName('.gitkeep'), '.gitkeep');
    });
  });

  group('the catalog', () {
    TableSpec specFor(String table) =>
        adminCatalog.firstWhere((spec) => spec.table == table);

    test('the three document columns are declared, and editable', () {
      final subjects = specFor('subjects');
      expect(subjects.fieldFor('notes_link')!.type, FieldType.documentList);
      expect(subjects.fieldFor('notes_link')!.bucketFolder, BucketFolder.notes);
      expect(subjects.fieldFor('lab_manual_link')!.type, FieldType.fileUrl);
      expect(subjects.fieldFor('lab_manual_link')!.bucketFolder,
          BucketFolder.labManual);

      final branches = specFor('branches');
      expect(branches.fieldFor('study_materials')!.type,
          FieldType.documentList);
      expect(branches.fieldFor('study_materials')!.bucketFolder,
          BucketFolder.studyMaterials);
    });
  });

  group('FieldCodec', () {
    FieldSpec fieldFor(String table, String column) =>
        adminCatalog.firstWhere((spec) => spec.table == table).fieldFor(column)!;

    test('the JSON goes over the wire as the string it is', () {
      // Both columns are `text`: decoding here would send an object to a text
      // column, and PostgREST would stringify it back with its own spacing.
      final field = fieldFor('subjects', 'notes_link');
      const cell = '[{"name": "M1", "link": "https://pub.r2.dev/m1.pdf"}]';
      expect(FieldCodec.encode(field, cell), cell);
      expect(FieldCodec.decode(field, cell), cell);
    });

    test('a blank clears the column rather than storing empty JSON', () {
      final field = fieldFor('branches', 'study_materials');
      expect(FieldCodec.encode(field, '  '), isNull);
    });

    test('a cell yielding no file is refused before it is saved', () {
      // The student app silently skips a link it cannot open, so a typo here
      // would save, look saved, and offer the student nothing.
      final field = fieldFor('subjects', 'notes_link');
      expect(FieldCodec.validate(field, 'waiting for the key'), isNotNull);
      expect(
        FieldCodec.validate(field, '[{"name": "A", "link": "not a url"}]'),
        isNotNull,
      );
      expect(
        FieldCodec.validate(
            field, '[{"name": "A", "link": "https://pub.r2.dev/a.pdf"}]'),
        isNull,
      );
      // A bare URL is what a hand-typed cell looks like, and it is fine.
      expect(FieldCodec.validate(field, 'https://pub.r2.dev/a.pdf'), isNull);
    });
  });
}
