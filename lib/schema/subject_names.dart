/// Turning a `py_qp` row's subject code into the subject's name.
///
/// A `py_qp` row names its subject by code and nothing else — the table has no
/// name column — so the list that edits it can only show `1BMATC101`, which does
/// not say which subject that is. The name lives in `subjects.sub_name`.
///
/// Read as one index rather than a lookup per row. `AdminRepository.subjectForCode`
/// already resolves a code to a subject, but it is one request per code, which
/// suits the upload flow (a handful of codes, cached for the session) and not a
/// list (up to eighty codes on the first page alone). `subjects` is 221 rows, so
/// reading the lot once costs less than a request per code.
library;

/// The `subjects` columns a code can live in. A first-year row carries one code
/// per half of the year; from the third semester on, only one is filled.
const List<String> subjectCodeColumns = ['sem_1_sub_code', 'sem_2_sub_code'];

/// Splits a code cell into the codes it holds, upper-cased.
///
/// One cell can name the same subject under two branches — `1BAS302 / 1BAE302` —
/// and a `py_qp` row carries whichever half it happened to be created with, so
/// matching the cell as written would miss half those papers. Sixteen `subjects`
/// rows store a cell this way.
Iterable<String> codesInCell(Object? cell) sync* {
  for (final part in (cell ?? '').toString().split('/')) {
    final code = part.trim().toUpperCase();
    if (code.isNotEmpty) yield code;
  }
}

/// Subject code (upper-case) to subject name.
///
/// A code carried by more than one row keeps the first name it is given:
/// `1BCP308` sits on six rows, one per branch, and they agree about the subject.
/// A row with no name contributes nothing, so its codes resolve to null rather
/// than to an empty string that would print as a blank.
Map<String, String> subjectNameIndex(
  Iterable<Map<String, dynamic>> subjectRows,
) {
  final index = <String, String>{};
  for (final row in subjectRows) {
    final name = (row['sub_name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    for (final column in subjectCodeColumns) {
      for (final code in codesInCell(row[column])) {
        index.putIfAbsent(code, () => name);
      }
    }
  }
  return index;
}

/// The subject name for one row, or null when none of [columns] resolves.
///
/// Null is not "no name" — it is "this code names no subject", which the list
/// prints as a dash so a code that was mistyped looks wrong instead of looking
/// like a subject nobody has named yet.
String? subjectNameFor(
  Map<String, String> index,
  Map<String, dynamic> row,
  List<String> columns,
) {
  if (index.isEmpty) return null;
  for (final column in columns) {
    for (final code in codesInCell(row[column])) {
      final name = index[code];
      if (name != null) return name;
    }
  }
  return null;
}
