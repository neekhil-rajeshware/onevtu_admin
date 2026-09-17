import 'package:flutter/foundation.dart';

import '../r2/bucket_layout.dart';

/// How one column is edited and rendered.
enum FieldType {
  text,
  multiline,

  /// Whole numbers (`semester`, `sort_order`, `zone_code`).
  integer,

  /// `numeric` columns like `store.price`.
  decimal,
  boolean,

  /// `date` columns — `exam_timetable.exam_date`.
  date,

  /// `timestamptz` columns — shown, and editable, in local time.
  dateTime,

  /// Fixed or looked-up set of values, rendered as a dropdown.
  select,

  /// Postgres `text[]`, edited as chips.
  tags,

  /// A plain URL, with an "open" button.
  url,

  /// A URL that may live in the R2 bucket: gets upload / browse / open.
  fileUrl,

  /// `jsonb`, edited as validated raw JSON.
  json,

  /// A `gatepyqs` year column: `text` holding JSON that names this year's paper,
  /// answer key and solved paper, each possibly once per GATE session. Edited by
  /// ticking files in the branch's bucket folder — see `schema/gate_assets.dart`.
  gateAssets,

  /// `text` holding JSON that lists files by name: `subjects.notes_link` and
  /// `branches.study_materials`, where one row publishes several documents and
  /// the student sees one button per document. Edited by ticking files in the
  /// row's bucket folder — see `schema/named_documents.dart`.
  ///
  /// Unlike [gateAssets] there is nothing about a file to *classify*: every
  /// entry is the same shape, and the only thing to get right is what to call
  /// it.
  documentList,
}

/// Where a [FieldType.select]'s options come from when they aren't a fixed list.
@immutable
class Lookup {
  const Lookup({
    required this.table,
    required this.valueColumn,
    this.labelColumn,
    this.distinct = false,
    this.orderBy,
  });

  final String table;
  final String valueColumn;

  /// Shown beside the value, e.g. `2025 CBCS` for scheme code `1`.
  final String? labelColumn;

  /// True when the options are the values already used in a column rather than
  /// rows of a reference table (`subjects.sub_category` has no table of its own).
  final bool distinct;

  final String? orderBy;

  String get cacheKey => '$table.$valueColumn.${labelColumn ?? ''}$distinct';
}

/// One editable column.
@immutable
class FieldSpec {
  const FieldSpec(
    this.column,
    this.label, {
    this.type = FieldType.text,
    this.required = false,
    this.notNull = false,
    this.help,
    this.options,
    this.lookup,
    this.readOnly = false,
    this.maxLines = 1,
    this.uploadPrefix,
    this.bucketFolder = BucketFolder.flat,
    this.freeTextSelect = false,
    this.defaultValue,
  });

  final String column;
  final String label;
  final FieldType type;

  /// Blocks a save when empty. Mirrors `NOT NULL` — nothing more clever, since
  /// the database is still the authority.
  final bool required;

  /// The column is `NOT NULL` but a blank value is legitimate, so an empty field
  /// is saved as `''` instead of null. `gatepyqs."2014"` is the case: the column
  /// rejects null, yet a branch may genuinely have no 2014 paper.
  final bool notNull;

  /// Shown under the field. Worth writing for anything a non-obvious column
  /// means, because this app is the documentation.
  final String? help;

  /// Fixed dropdown values.
  final List<String>? options;

  /// Dropdown values read from the database.
  final Lookup? lookup;

  final bool readOnly;
  final int maxLines;

  /// Default folder for [FieldType.fileUrl] uploads on a column the bucket layout
  /// says nothing about — a job attachment, a project thumbnail. Academic content
  /// uses [bucketFolder] instead, which works the folder out from the row.
  final String? uploadPrefix;

  /// Which part of the bucket tree an academic file belongs in, so an upload lands
  /// in `vtu/scheme-2025/1st_year/` by itself instead of wherever the person
  /// typing happened to be. See `r2/bucket_layout.dart`.
  final BucketFolder bucketFolder;

  /// Lets a [FieldType.select] also accept a value that isn't in the list —
  /// needed where the column is free text that merely tends to repeat.
  final bool freeTextSelect;

  /// What a *new* row starts with, written the way the form holds it (`'true'`
  /// for a boolean). Worth setting wherever the column has a non-blank default:
  /// an untouched switch renders off, so without this the form shows `off` while
  /// the database is about to store `true`.
  final String? defaultValue;

  bool get isSelect => type == FieldType.select;
}
