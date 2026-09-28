import 'package:flutter/material.dart';

import 'field_spec.dart';

/// A filter chip above a collection list.
@immutable
class FilterSpec {
  const FilterSpec(
    this.column,
    this.label, {
    this.options,
    this.lookup,
  });

  final String column;
  final String label;
  final List<String>? options;
  final Lookup? lookup;
}

/// Everything the generic list + form screens need to know about one table.
///
/// The whole console is driven by these: adding a table to the catalog is the
/// only step needed to make it editable, which is why there is no per-table
/// screen anywhere in this app.
@immutable
class TableSpec {
  const TableSpec({
    required this.table,
    required this.title,
    required this.description,
    required this.icon,
    required this.group,
    required this.primaryKey,
    required this.fields,
    this.primaryKeyIsGenerated = true,
    this.searchColumns = const [],
    this.orderBy,
    this.ascending = true,
    this.filters = const [],
    this.canCreate = true,
    this.canDelete = true,
    this.canSendPush = false,
    this.canModerate = false,
    this.titleColumns = const [],
    this.subtitleColumns = const [],
    this.subjectCodeColumns = const [],
    this.thumbnailColumn,
  });

  final String table;

  /// What the owner calls this, not what Postgres calls it.
  final String title;

  /// One line on the dashboard card explaining what editing this changes.
  final String description;

  final IconData icon;

  /// Dashboard section: `Academic data`, `Content`, `App`.
  final String group;

  final String primaryKey;

  /// False when the key is typed by hand (`colleges.code`, `app_links.key`,
  /// `formulas.title`). Generated keys are never sent on insert — `subjects.id`
  /// is `GENERATED ALWAYS`, which rejects an explicit value outright.
  final bool primaryKeyIsGenerated;

  final List<FieldSpec> fields;

  /// Columns the search box matches with `ilike`.
  final List<String> searchColumns;

  final String? orderBy;
  final bool ascending;
  final List<FilterSpec> filters;
  final bool canCreate;
  final bool canDelete;

  /// Puts a Send-to-phones action on every row and in the editor. Only
  /// `notifications` sets it: the `send-push` Edge Function takes the audience
  /// off the row, so there is nothing table-agnostic about sending anything else.
  final bool canSendPush;

  /// Puts Approve / Not approved on every row and in the editor. Only `store`
  /// sets it: a student's listing is created `pending` and stays off the Store
  /// until it is approved here, so this table is a queue and not just a list.
  ///
  /// A table that sets it must declare `status` and `review_note` — those are the
  /// two columns the buttons write.
  final bool canModerate;

  /// Columns joined for a row's headline; falls back to the primary key.
  final List<String> titleColumns;

  /// Columns joined, `label: value` style, for a row's second line.
  final List<String> subtitleColumns;

  /// Columns holding a subject code, whose `subjects.sub_name` is appended to
  /// the row's headline. Empty for every table but `py_qp`.
  ///
  /// A `py_qp` row is identified by a code and carries no name of its own, so
  /// without this the list reads `1BMATC101 · 1BMATC201` and nothing more. The
  /// name is read once for the whole table's worth of codes — see
  /// `schema/subject_names.dart` — rather than joined, because there is no
  /// foreign key between the two tables to join on.
  final List<String> subjectCodeColumns;

  /// Column holding a picture of the row, shown as a thumbnail in the list.
  ///
  /// Only for a column whose value really is one image the row *is about* — a
  /// store listing's photo, a project's thumbnail. Not every `fileUrl` column
  /// qualifies: a syllabus PDF is a document attached to a subject, and a row of
  /// broken-image squares down the subjects list would say nothing.
  final String? thumbnailColumn;

  FieldSpec? fieldFor(String column) {
    for (final field in fields) {
      if (field.column == column) return field;
    }
    return null;
  }

  /// Columns the app writes. The primary key of a hand-keyed table is included
  /// on insert only — see `AdminRepository.update`.
  Iterable<FieldSpec> get writableFields =>
      fields.where((f) => !f.readOnly);
}
