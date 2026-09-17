import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/r2/bucket_layout.dart';

/// The bucket has one shape, and every upload has to land in it without being
/// told. These tests are that shape written down: the folder names, who decides
/// them, and the two rules that keep the tree readable a year from now — first
/// year is one folder, and every level keeps its own bin.
const _names = BucketNames(
  schemes: {'1': '2025 CBCS', '2': '2022 CBCS', '3': '2018 CBCS'},
  branches: {
    'AE': 'Aeronautical Engineering',
    'CT': 'Construction Technology & Management',
  },
);

void main() {
  group('folder names', () {
    test('a scheme is named by its year, not its code', () {
      // `scheme_code` is '1'; nobody browsing the bucket next year knows that.
      expect(schemeFolderName('2025 CBCS'), 'scheme-2025');
      expect(schemeFolderName('2018 CBCS'), 'scheme-2018');
      expect(schemeFolderName('CBCS'), isNull);
    });

    test('a branch keeps its code and its full name', () {
      expect(branchFolderName('AE', 'Aeronautical Engineering'),
          'AE_Aeronautical_Engineering');
      expect(branchFolderName('CT', 'Construction Technology & Management'),
          'CT_Construction_Technology_&_Management');
    });

    test('semesters 1 and 2 are one folder, and so is a cycle subject', () {
      // VTU teaches the first year as a year: '1 & 2' is a real value in the
      // semester column, and a cycle subject has no semester at all.
      expect(levelFolderName('1'), '1st_year');
      expect(levelFolderName('2'), '1st_year');
      expect(levelFolderName('1 & 2'), '1st_year');
      expect(levelFolderName(null), '1st_year');
      expect(levelFolderName(''), '1st_year');
    });

    test('from the third semester each gets its own folder', () {
      expect(levelFolderName('3'), '3rd_sem');
      expect(levelFolderName('5'), '5th_sem');
      expect(levelFolderName('8'), '8th_sem');
      expect(levelFolderName('9'), isNull); // not a VTU semester
    });

    test('a name keeps its capitals and spaces, and loses only what breaks', () {
      // The 65 syllabus links already in the database are spelt this way;
      // lower-casing would file the next upload beside them instead of with them.
      expect(bucketSafeName('Introduction to UAV Systems'),
          'Introduction to UAV Systems');
      expect(bucketSafeName('Multivariable Calculus: ME Stream'),
          'Multivariable Calculus_ ME Stream');
      expect(bucketSafeName('a/b?c#d%e.pdf'), 'a b c d e.pdf');
      expect(bucketSafeName('  double  spaced  '), 'double spaced');
    });
  });

  group('where a file goes', () {
    test('a first-year syllabus sits under the scheme, branch or no branch', () {
      // 29 of the rows with links name a branch and are still first-year files:
      // the branch folder only starts once the branch does, in semester 3.
      expect(
        bucketFolderFor(BucketFolder.syllabus,
            {'scheme_code': '1', 'semester': '1 & 2', 'branch': 'AE'},
            names: _names),
        'vtu/scheme-2025/1st_year/',
      );
    });

    test('a later syllabus goes under its branch and semester', () {
      expect(
        bucketFolderFor(BucketFolder.syllabus,
            {'scheme_code': '2', 'semester': '3', 'branch': 'AE'},
            names: _names),
        'vtu/scheme-2022/AE_Aeronautical_Engineering/3rd_sem/',
      );
    });

    test('a question paper goes in the subject folder inside py_qp', () {
      expect(
        bucketFolderFor(
          BucketFolder.questionPaper,
          {'scheme_code': '1', 'semester': '3', 'branch_code': 'AE',
            'sem_1_sub_code': '1BAE305'},
          names: _names,
          subjectName: 'Introduction to UAV Systems and Technologies',
        ),
        'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/py_qp/'
            '1BAE305 Introduction to UAV Systems and Technologies/',
      );
    });

    test('a question paper still files under the bare code with no name', () {
      // The name is a second query and may not come back; the code alone is
      // still in the right place, which is what matters.
      expect(
        bucketFolderFor(BucketFolder.questionPaper,
            {'scheme_code': '1', 'semester': '1', 'sem_2_sub_code': '1BMATC201'},
            names: _names),
        'vtu/scheme-2025/1st_year/py_qp/1BMATC201/',
      );
    });

    test('a GATE paper is branch-wise and scheme-less', () {
      expect(
        bucketFolderFor(BucketFolder.gatePaper, {'code': 'AE'}, names: _names),
        'vtu/gatepyqs/AE_Aeronautical_Engineering/',
      );
      // An unknown code still lands inside gatepyqs rather than nowhere.
      expect(
        bucketFolderFor(BucketFolder.gatePaper, {'code': 'XX'}, names: _names),
        'vtu/gatepyqs/XX/',
      );
    });

    test('notes share one folder per semester, with no subject level', () {
      expect(
        bucketFolderFor(BucketFolder.notes,
            {'scheme_code': '1', 'semester': '3', 'branch': 'AE'},
            names: _names),
        'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/notes/',
      );
    });

    test('a lab manual goes straight into the semester folder', () {
      // Not a `lab_manuals/` folder and not a subject folder: this is the one
      // document that sits loose beside `py_qp/` and `notes/`, and its own name
      // is what says which subject it is for.
      expect(
        bucketFolderFor(BucketFolder.labManual,
            {'scheme_code': '1', 'semester': '3', 'branch': 'AE'},
            names: _names),
        'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/',
      );
    });

    test('study materials hang off the branch, under vtu/branches', () {
      expect(
        bucketFolderFor(BucketFolder.studyMaterials, {'code': 'AE'},
            names: _names),
        'vtu/branches/AE_Aeronautical_Engineering/study_materials/',
      );
      // A branch with no code has no folder — `branches.code` is the key the
      // whole tree is built from.
      expect(
        bucketFolderFor(BucketFolder.studyMaterials, const {}, names: _names),
        isNull,
      );
    });

    test('nothing is guessed when the row cannot place it', () {
      // A folder invented from half a row is a folder somebody has to find and
      // clean up later, so these ask for a key instead.
      expect(
        bucketFolderFor(BucketFolder.syllabus, {'semester': '3'}, names: _names),
        isNull,
        reason: 'no scheme',
      );
      expect(
        bucketFolderFor(BucketFolder.syllabus,
            {'scheme_code': '1', 'semester': '5'},
            names: _names),
        isNull,
        reason: 'a fifth-semester subject with no branch',
      );
      expect(
        bucketFolderFor(BucketFolder.syllabus,
            {'scheme_code': '9', 'semester': '1'},
            names: _names),
        isNull,
        reason: 'a scheme the lookup does not know',
      );
      expect(bucketFolderFor(BucketFolder.flat, const {}), isNull);
    });
  });

  group('what a file is called', () {
    test('a syllabus is its code and its subject name', () {
      expect(
        bucketBaseNameFor(
          BucketFolder.syllabus,
          {
            'sem_1_sub_code': '1BMATC101',
            'sub_name': 'Differential Calculus and Linear Algebra: CV Stream',
          },
          column: 'syllabus_link',
        ),
        '1BMATC101 Differential Calculus and Linear Algebra_ CV Stream',
      );
    });

    test('a paper is its session, because the folder already says the subject',
        () {
      expect(
        bucketBaseNameFor(BucketFolder.questionPaper, const {},
            column: 'june_july_2025'),
        'june_july_2025',
      );
      expect(
        bucketBaseNameFor(BucketFolder.gatePaper, const {}, column: '2014'),
        '2014',
      );
    });

    test('a flat column keeps whatever the file was called', () {
      expect(bucketBaseNameFor(BucketFolder.flat, const {}, column: 'file_path'),
          isNull);
    });

    test('a lab manual is named after its subject, like the syllabus', () {
      // Both live loose in the semester folder, so the name is the only thing
      // that says which subject either one belongs to.
      expect(
        bucketBaseNameFor(
          BucketFolder.labManual,
          {'sem_1_sub_code': '1BAE305', 'sub_name': 'Introduction to UAV Systems'},
          column: 'lab_manual_link',
        ),
        '1BAE305 Introduction to UAV Systems',
      );
    });

    test('notes and study materials keep the name they were picked with', () {
      // One `notes/` holds every subject's notes and one `study_materials/`
      // holds everything a branch publishes, so nothing here can tell two files
      // apart — only the person naming the file can, and the upload still
      // offers the key for editing before it is used.
      expect(
        bucketBaseNameFor(BucketFolder.notes,
            {'sem_1_sub_code': '1BAE305', 'sub_name': 'Introduction to UAV'},
            column: 'notes_link'),
        isNull,
      );
      expect(
        bucketBaseNameFor(BucketFolder.studyMaterials, {'code': 'AE'},
            column: 'study_materials'),
        isNull,
      );
    });
  });

  group('the archive', () {
    final when = DateTime(2026, 8, 31, 14, 32, 5);
    const stamp = '2026-08-31_143205';

    test('is the one at the file\'s own level', () {
      expect(
        archiveKeyFor('vtu/scheme-2025/1st_year/1BMATC101 Calculus.pdf', when),
        'vtu/scheme-2025/1st_year/$archiveFolderName/$stamp/'
            '1BMATC101 Calculus.pdf',
      );
    });

    test('keeps the path below the level, so it still says what it was', () {
      // A shared bin at the bucket root becomes thousands of files nobody dares
      // touch; a bin per semester stays readable.
      expect(
        archiveKeyFor(
          'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/py_qp/'
              '1BAE305 UAV Systems/june_july_2025.pdf',
          when,
        ),
        'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/$archiveFolderName/'
            '$stamp/py_qp/1BAE305 UAV Systems/june_july_2025.pdf',
      );
    });

    test('falls back to the file\'s own folder outside a semester', () {
      expect(
        archiveKeyFor('vtu/gatepyqs/AE_Aeronautical_Engineering/2014.pdf', when),
        'vtu/gatepyqs/AE_Aeronautical_Engineering/$archiveFolderName/$stamp/'
            '2014.pdf',
      );
      expect(archiveKeyFor('loose.pdf', when),
          '$archiveFolderName/$stamp/loose.pdf');
    });

    test('recognises a bin anywhere in the tree', () {
      // Whatever is already in one is deleted for real — otherwise the bin could
      // never be emptied.
      expect(isInArchive('vtu/scheme-2025/1st_year/$archiveFolderName/x/a.pdf'),
          isTrue);
      expect(isInArchive('$archiveFolderName/x/a.pdf'), isTrue);
      expect(isInArchive('vtu/scheme-2025/1st_year/a.pdf'), isFalse);
    });

    test('separates two replacements of the same file by the second', () {
      expect(
        archiveKeyFor('a.pdf', when),
        isNot(archiveKeyFor('a.pdf', when.add(const Duration(seconds: 1)))),
      );
    });
  });

  group('the folders offered when making one', () {
    const branches = {'AE': 'Aeronautical Engineering'};
    const schemes = ['2025 CBCS', '2022 CBCS'];

    test('only vtu belongs at the root', () {
      expect(standardChildrenOf(''), ['vtu']);
    });

    test('the schemes and the branch tree sit one level in', () {
      // `branches/` and `gatepyqs/` are both branch-wise and scheme-less, so
      // neither can live inside a scheme folder.
      expect(
        standardChildrenOf('vtu/', schemeNames: schemes),
        ['branches', 'gatepyqs', 'scheme-2022', 'scheme-2025'],
      );
    });

    test('a scheme offers first year and the branches', () {
      expect(
        standardChildrenOf('vtu/scheme-2025/', branches: branches),
        ['1st_year', 'AE_Aeronautical_Engineering'],
      );
    });

    test('a branch offers the semesters it teaches', () {
      expect(
        standardChildrenOf('vtu/scheme-2025/AE_Aeronautical_Engineering/'),
        ['3rd_sem', '4th_sem', '5th_sem', '6th_sem', '7th_sem', '8th_sem'],
      );
    });

    test('a GATE branch offers the three kinds, and no year level', () {
      // There is no `2026` folder under a branch: the year is in the file name.
      // A `<year>/<kind>/` tree existed for one day and was removed; a bare
      // branch with no kind folders existed for a few minutes after that. This
      // is the shape that was asked for.
      expect(standardChildrenOf('vtu/gatepyqs/AE_Aeronautical_Engineering/'),
          ['answer_key', 'papers', 'solved_papers']);
      // Making a branch makes its kinds with it, the way making a semester makes
      // py_qp — a branch without them has nowhere for an upload to go.
      expect(requiredChildrenOf('vtu/gatepyqs/AE_Aeronautical_Engineering/'),
          ['answer_key', 'papers', 'solved_papers']);
      // Nothing is offered below a kind: the files go straight in.
      expect(
          standardChildrenOf(
              'vtu/gatepyqs/AE_Aeronautical_Engineering/answer_key/'),
          isEmpty);
      expect(
          requiredChildrenOf(
              'vtu/gatepyqs/AE_Aeronautical_Engineering/answer_key/'),
          isEmpty);
      // The branch folders themselves are still offered one level up, from the
      // database rather than hard-coded.
      expect(standardChildrenOf('vtu/gatepyqs/', branches: branches),
          ['AE_Aeronautical_Engineering']);
    });

    test('a semester comes with its papers folder and its bin', () {
      const semester = 'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem/';
      // `notes/` is offered but not required: a semester with nothing uploaded
      // for it yet is not a broken semester. There is no lab-manual folder at
      // all — a lab manual goes straight into the semester, named after its
      // subject.
      expect(standardChildrenOf(semester),
          ['py_qp', 'notes', archiveFolderName]);
      // And those two are made with it, not left to the first upload.
      expect(requiredChildrenOf(semester), ['py_qp', archiveFolderName]);
      expect(requiredChildrenOf('vtu/scheme-2025/1st_year/'),
          ['py_qp', archiveFolderName]);
      expect(requiredChildrenOf('vtu/'), isEmpty);
    });

    test('a branch under vtu/branches is study materials and a bin', () {
      const branch = 'vtu/branches/AE_Aeronautical_Engineering/';
      expect(standardChildrenOf('vtu/branches/', branches: branches),
          ['AE_Aeronautical_Engineering']);
      expect(standardChildrenOf(branch),
          ['study_materials', archiveFolderName]);
      // The branch folder exists for these and nothing else, so making it makes
      // the folder — a branch that can never be uploaded into is not a branch
      // anybody wanted.
      expect(requiredChildrenOf(branch), ['study_materials']);
      expect(standardChildrenOf('${branch}study_materials/'),
          [archiveFolderName]);
    });
  });
}
