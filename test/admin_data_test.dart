import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/r2/upload_flow.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/schema/field_spec.dart';

void main() {
  group('encode', () {
    test('an empty optional column clears to null', () {
      const field = FieldSpec('syllabus_link', 'Syllabus', type: FieldType.fileUrl);
      expect(FieldCodec.encode(field, ''), isNull);
      expect(FieldCodec.encode(field, '   '), isNull);
    });

    test('an empty required text column gets an empty string, not null', () {
      // gatepyqs."2014" is NOT NULL, so null would be rejected outright.
      const field = FieldSpec('2014', '2014', required: true);
      expect(FieldCodec.encode(field, ''), '');
    });

    test('a notNull column saves blank without demanding a value', () {
      // The real gatepyqs."2014": null is rejected by the column, but a branch
      // with no 2014 paper still has to be creatable.
      const field =
          FieldSpec('2014', '2014', type: FieldType.fileUrl, notNull: true);
      expect(FieldCodec.encode(field, ''), '');
      expect(FieldCodec.validate(field, ''), isNull);
    });

    test('numbers arrive as numbers', () {
      const semester = FieldSpec('semester', 'Semester', type: FieldType.integer);
      const price = FieldSpec('price', 'Price', type: FieldType.decimal);
      expect(FieldCodec.encode(semester, '3'), 3);
      expect(FieldCodec.encode(price, '199.50'), 199.5);
    });

    test('tags become a Postgres array', () {
      const field = FieldSpec('tags', 'Tags', type: FieldType.tags);
      expect(FieldCodec.encode(field, 'ai, ml , ,vision'),
          ['ai', 'ml', 'vision']);
    });

    test('json is decoded so PostgREST stores jsonb, not a string', () {
      const field = FieldSpec('variables', 'Variables', type: FieldType.json);
      expect(FieldCodec.encode(field, '{"a": 1}'), {'a': 1});
    });

    test('booleans are real booleans', () {
      const field = FieldSpec('is_active', 'Active', type: FieldType.boolean);
      expect(FieldCodec.encode(field, 'true'), isTrue);
      expect(FieldCodec.encode(field, 'false'), isFalse);
      // An untouched switch is `false`, never null.
      expect(FieldCodec.encode(field, ''), isNull);
    });

    test('a local wall-clock time is converted to UTC', () {
      const field = FieldSpec('starts_at', 'Starts', type: FieldType.dateTime);
      final encoded = FieldCodec.encode(field, '2026-08-29 21:00') as String;
      expect(encoded, endsWith('Z'));
      expect(
        DateTime.parse(encoded).toLocal(),
        DateTime(2026, 8, 29, 21),
      );
    });

    test('a date stays a plain calendar day', () {
      const field = FieldSpec('exam_date', 'Exam date', type: FieldType.date);
      expect(FieldCodec.encode(field, '2026-11-20'), '2026-11-20');
    });
  });

  group('decode', () {
    test('null becomes empty text so the form shows a blank field', () {
      const field = FieldSpec('sub_name', 'Name');
      expect(FieldCodec.decode(field, null), '');
    });

    test('an array comes back as a comma list', () {
      const field = FieldSpec('tags', 'Tags', type: FieldType.tags);
      expect(FieldCodec.decode(field, ['ai', 'ml']), 'ai, ml');
    });

    test('json is pretty-printed for editing', () {
      const field = FieldSpec('variables', 'Variables', type: FieldType.json);
      expect(FieldCodec.decode(field, {'a': 1}), '{\n  "a": 1\n}');
    });

    test('a timestamp round-trips through the form unchanged', () {
      const field = FieldSpec('starts_at', 'Starts', type: FieldType.dateTime);
      final stored = DateTime(2026, 8, 29, 21, 5).toUtc().toIso8601String();
      final shown = FieldCodec.decode(field, stored);
      expect(shown, '2026-08-29 21:05');
      expect(FieldCodec.encode(field, shown), stored);
    });
  });

  group('validate', () {
    test('required means required', () {
      const field = FieldSpec('sub_code', 'Code', required: true);
      expect(FieldCodec.validate(field, ''), isNotNull);
      expect(FieldCodec.validate(field, 'BCS301'), isNull);
    });

    test('a link must look like one', () {
      const field = FieldSpec('syllabus_link', 'Syllabus', type: FieldType.fileUrl);
      expect(FieldCodec.validate(field, 'pub-x.r2.dev/a.pdf'), isNotNull);
      expect(FieldCodec.validate(field, 'https://pub-x.r2.dev/a.pdf'), isNull);
      // Optional and empty is fine.
      expect(FieldCodec.validate(field, ''), isNull);
    });

    test('bad numbers and bad json are caught before the round trip', () {
      const number = FieldSpec('semester', 'Semester', type: FieldType.integer);
      const json = FieldSpec('variables', 'Variables', type: FieldType.json);
      expect(FieldCodec.validate(number, '3rd'), isNotNull);
      expect(FieldCodec.validate(json, '{oops}'), isNotNull);
    });
  });

  group('object keys', () {
    test('keep the name and drop only what would break a key or a URL', () {
      // The bucket's convention is capitals and spaces — `bucket_layout.dart`
      // explains why flattening a name would file the next upload away from the
      // files it belongs with.
      expect(sanitizeKeySegment('2022 Scheme — CS (Module 3).pdf'),
          '2022 Scheme — CS (Module 3).pdf');
      expect(sanitizeKeySegment('CS/Module?3#x.pdf'), 'CS Module 3 x.pdf');
      expect(sanitizeKeySegment('   '), 'file');
    });

    test('carry a content type so a PDF opens instead of downloading', () {
      expect(contentTypeFor('cs.pdf'), 'application/pdf');
      expect(contentTypeFor('thumb.PNG'), 'image/png');
      expect(contentTypeFor('noextension'), 'application/octet-stream');
    });
  });

  group('catalog', () {
    test('every table names a primary key that is one of its fields or hidden',
        () {
      for (final spec in adminCatalog) {
        expect(spec.primaryKey, isNotEmpty, reason: spec.table);
        if (!spec.primaryKeyIsGenerated) {
          // A hand-keyed table must expose its key, or a row could never be
          // created.
          expect(spec.fieldFor(spec.primaryKey), isNotNull,
              reason: '${spec.table} needs an editable ${spec.primaryKey}');
        }
      }
    });

    test('every spec has fields, a group and a description', () {
      for (final spec in adminCatalog) {
        expect(spec.fields, isNotEmpty, reason: spec.table);
        expect(catalogGroups, contains(spec.group), reason: spec.table);
        expect(spec.description, isNotEmpty, reason: spec.table);
      }
    });

    test('no table declares the same column twice', () {
      for (final spec in adminCatalog) {
        final columns = spec.fields.map((f) => f.column).toList();
        expect(columns.toSet().length, columns.length, reason: spec.table);
      }
    });

    test('search, filter and display columns all exist as fields', () {
      for (final spec in adminCatalog) {
        for (final column in [
          ...spec.searchColumns,
          ...spec.titleColumns,
          ...spec.subtitleColumns,
          ...spec.filters.map((f) => f.column),
        ]) {
          expect(spec.fieldFor(column), isNotNull,
              reason: '${spec.table}.$column is referenced but not declared');
        }
      }
    });

    test('every select field can offer options', () {
      for (final spec in adminCatalog) {
        for (final field in spec.fields.where((f) => f.isSelect)) {
          expect(field.options != null || field.lookup != null, isTrue,
              reason: '${spec.table}.${field.column} has no options');
        }
      }
    });

    test('a moderated table declares the columns the buttons write', () {
      for (final spec in adminCatalog.where((s) => s.canModerate)) {
        for (final column in ['status', 'review_note']) {
          expect(spec.fieldFor(column), isNotNull,
              reason: '${spec.table} is moderated but has no $column');
        }
      }
    });

    test('specForTable finds what the catalog holds', () {
      expect(specForTable('subjects')?.title, isNotNull);
      expect(specForTable('not_a_table'), isNull);
    });

    group('the announcement audience', () {
      final spec = specForTable('notifications')!;

      test('offers branch names, not branch codes', () {
        // The push topic is built from this string and compared against
        // `profiles.branch`, which holds "Civil Engineering", not "CV". A code
        // here would send successfully to a topic nobody subscribes to.
        for (final branch in [
          spec.fieldFor('branch_code')!.lookup,
          spec.filters.firstWhere((f) => f.column == 'branch_code').lookup,
        ]) {
          expect(branch?.table, 'branches');
          expect(branch?.valueColumn, 'name');
        }
      });

      test('is picked, never typed', () {
        // A misspelt branch or scheme is not a typo you can see: the send
        // reports success and no phone buzzes.
        for (final column in ['branch_code', 'scheme_code', 'semester']) {
          final field = spec.fieldFor(column)!;
          expect(field.type, FieldType.select, reason: '$column is not a picker');
          expect(field.freeTextSelect, isFalse, reason: '$column accepts typing');
        }
      });

      test('lists the eight semesters', () {
        expect(spec.fieldFor('semester')!.options, [
          '1', '2', '3', '4', '5', '6', '7', '8', //
        ]);
      });
    });

    group('narrowing the subject list', () {
      final spec = specForTable('subjects')!;

      test('can be narrowed by branch', () {
        expect(
          spec.filters.map((f) => f.column),
          containsAll(['scheme_code', 'semester', 'stream', 'branch']),
        );
      });

      test('offers branch codes, not branch names', () {
        // The mirror image of the announcement audience above, and the reason
        // both are tested: `subjects.branch` holds `AE`, while
        // `notifications.branch_code` holds `Aeronautical Engineering`. Swapping
        // the two lookups breaks nothing loudly — the query is valid and simply
        // matches no row, which reads as "no subjects in this branch yet".
        for (final branch in [
          spec.fieldFor('branch')!.lookup,
          spec.filters.firstWhere((f) => f.column == 'branch').lookup,
        ]) {
          expect(branch?.table, 'branches');
          expect(branch?.valueColumn, 'code');
        }
      });
    });

    group('the profiles table', () {
      final spec = specForTable('profiles')!;

      test('is read-only from here', () {
        // There is no admin INSERT policy on `profiles`, and the only UPDATE
        // policy is `id = auth.uid()` — so a form offering to save would be
        // refused by the database on every row but your own. Marking the columns
        // read-only turns that into "Nothing changed", which is at least true.
        expect(spec.canCreate, isFalse);
        expect(spec.canDelete, isFalse);
        expect(spec.writableFields, isEmpty);
      });

      test('filters branch by name, because that is what the column holds', () {
        // The mirror of the announcement audience below: `profiles.branch` holds
        // "Civil Engineering" and the push topics are built from that exact
        // string, so a code filter would quietly match no one.
        final branch =
            spec.filters.firstWhere((f) => f.column == 'branch').lookup;
        expect(branch?.table, 'branches');
        expect(branch?.valueColumn, 'name');
      });

      test('can search by the things an admin is handed', () {
        // Someone reports a problem by name, USN or college; the email is what
        // is on file when none of those matches.
        expect(spec.searchColumns, contains('usn'));
        expect(spec.searchColumns, contains('college_name'));
      });
    });

    group('the store queue', () {
      final spec = specForTable('store')!;

      test('is a queue: moderated, and never created from here', () {
        // A listing has to keep a real seller behind it, and there is no admin
        // INSERT policy for that reason.
        expect(spec.canModerate, isTrue);
        expect(spec.canCreate, isFalse);
      });

      test('filters on exactly the three statuses the CHECK allows', () {
        final status = spec.filters.firstWhere((f) => f.column == 'status');
        expect(status.options, ['pending', 'approved', 'rejected']);
      });

      test('shows the status without opening the row', () {
        // The queue is unusable if telling a waiting listing from a live one
        // means tapping into each one.
        expect(spec.subtitleColumns, contains('status'));
      });

      test('leaves the four review columns to the buttons', () {
        // The trigger stamps reviewed_at/reviewed_by off a change of status, so
        // a form that could set one without the other would only ever produce
        // rows whose stamp disagrees with their status.
        for (final column in [
          'status',
          'review_note',
          'reviewed_at',
          'reviewed_by',
        ]) {
          expect(spec.fieldFor(column)?.readOnly, isTrue,
              reason: '$column should not be typed');
        }
      });
    });
  });
}
