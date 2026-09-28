import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/schema/subject_names.dart';

/// Which subject a `py_qp` row is, worked out from its code alone.
///
/// The rule matters because the two tables disagree about how a code is spelled:
/// `subjects` can hold two codes in one cell, and a `py_qp` row carries whichever
/// half it was created with. Matching the cell as written shows a dash over half
/// the papers that exist, so these tests are that rule written down.
void main() {
  Map<String, dynamic> subject(String name, {String? sem1, String? sem2}) => {
        'sub_name': name,
        'sem_1_sub_code': sem1,
        'sem_2_sub_code': sem2,
      };

  test('indexes a code from either semester column', () {
    final index = subjectNameIndex([
      subject('Maths I', sem1: '1BMATC101'),
      subject('Maths II', sem2: '1BMATC201'),
    ]);

    expect(index['1BMATC101'], 'Maths I');
    expect(index['1BMATC201'], 'Maths II');
  });

  test('a two-branch cell answers to both of its codes', () {
    // Real third-semester aerospace rows: one subject under two branches, so
    // one cell names it twice.
    final index = subjectNameIndex([
      subject('Aerospace Structures', sem1: '1BAS302 / 1BAE302'),
    ]);

    expect(index['1BAS302'], 'Aerospace Structures');
    expect(index['1BAE302'], 'Aerospace Structures');
  });

  test('a paper filed under the second half of a cell finds its subject', () {
    final index = subjectNameIndex([
      subject('Aerospace Structures', sem1: '1BAS302 / 1BAE302'),
    ]);
    final row = {'sem_1_sub_code': '1BAE302', 'sem_2_sub_code': ''};

    expect(subjectNameFor(index, row, subjectCodeColumns),
        'Aerospace Structures');
  });

  test('falls back to the second code column when the first resolves to nothing',
      () {
    final index = subjectNameIndex([subject('Maths II', sem2: '1BMATC201')]);
    final row = {'sem_1_sub_code': '1BXYZ999', 'sem_2_sub_code': '1BMATC201'};

    expect(subjectNameFor(index, row, subjectCodeColumns), 'Maths II');
  });

  test('a code naming no subject resolves to null, not to an empty name', () {
    final index = subjectNameIndex([subject('Maths I', sem1: '1BMATC101')]);
    final row = {'sem_1_sub_code': '1BTYPO404'};

    expect(subjectNameFor(index, row, subjectCodeColumns), isNull);
  });

  test('a row with no code at all resolves to null', () {
    final index = subjectNameIndex([subject('Maths II', sem2: '1BMATC201')]);
    final row = {'sem_1_sub_code': '', 'sem_2_sub_code': '   '};

    expect(subjectNameFor(index, row, subjectCodeColumns), isNull);
  });

  test('spacing and case in the cell do not decide whether it matches', () {
    final index = subjectNameIndex([
      subject('Aerospace Structures', sem1: ' 1bas302 /1BAE302 '),
    ]);
    final row = {'sem_1_sub_code': '1bae302'};

    expect(subjectNameFor(index, row, subjectCodeColumns),
        'Aerospace Structures');
  });

  test('a code on several rows keeps the first name given', () {
    // `1BCP308` sits on six rows, one per branch, and they agree about the
    // subject — so which one wins is not worth caring about, only that one does.
    final index = subjectNameIndex([
      subject('Material Science', sem1: '1BCP308'),
      subject('Material Science', sem1: '1BCP308'),
    ]);

    expect(index['1BCP308'], 'Material Science');
  });

  test('a nameless row contributes no codes', () {
    final index = subjectNameIndex([
      subject('', sem1: '1BMATC101'),
      {'sub_name': null, 'sem_1_sub_code': '1BMATC102'},
    ]);

    expect(index, isEmpty);
  });

  test('an index that has not loaded yet resolves to null', () {
    // What the list leans on: before the read lands the index is empty, and the
    // screen shows no suffix at all rather than a dash on every row.
    expect(
      subjectNameFor(const {}, {'sem_1_sub_code': '1BMATC101'},
          subjectCodeColumns),
      isNull,
    );
  });
}
