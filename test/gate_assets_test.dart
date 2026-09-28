import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';
import 'package:onevtu_admin/r2/bucket_layout.dart';
import 'package:onevtu_admin/schema/catalog.dart';
import 'package:onevtu_admin/schema/field_spec.dart';
import 'package:onevtu_admin/schema/gate_assets.dart';

void main() {
  group('parseGateAssets', () {
    test('reads all three kinds, sessions and all', () {
      final assets = parseGateAssets('''
{
  "Paper": [
    {"label": "Session 1", "url": "https://pub.r2.dev/a.pdf"},
    {"label": "Session 2", "url": "https://pub.r2.dev/b.pdf"}
  ],
  "Answer Key": "https://pub.r2.dev/key.pdf",
  "Solved Papers": "https://pub.r2.dev/solved.pdf"
}
''');

      expect(assets, hasLength(4));
      expect(assets[0].kind, GateAssetKind.paper);
      expect(assets[0].label, 'Session 1');
      expect(assets[1].label, 'Session 2');
      expect(assets[2].kind, GateAssetKind.answerKey);
      expect(assets[2].label, isEmpty);
      expect(assets[3].kind, GateAssetKind.solvedPaper);
    });

    test('kinds come back in kind order whatever order the cell lists them', () {
      final assets = parseGateAssets(
        '{"Solved Papers": "https://d/s.pdf", "Paper": "https://d/p.pdf"}',
      );
      expect(assets.map((a) => a.kind),
          [GateAssetKind.paper, GateAssetKind.solvedPaper]);
    });

    test('loose key spelling and a label to url map', () {
      final assets = parseGateAssets(
        '{"answer_key": {"Session 1": "https://d/k1.pdf", '
        '"Session 2": "https://d/k2.pdf"}}',
      );
      expect(assets, hasLength(2));
      expect(assets.every((a) => a.kind == GateAssetKind.answerKey), isTrue);
      expect(assets.map((a) => a.label), ['Session 1', 'Session 2']);
    });

    test("a bare URL is that year's only paper", () {
      // The shape every cell held before this column became JSON. Nothing
      // already entered may stop opening.
      final assets = parseGateAssets('https://drive.google.com/file/d/AAA/view');
      expect(assets, hasLength(1));
      expect(assets.single.kind, GateAssetKind.paper);
      expect(assets.single.label, isEmpty);
    });

    test('a note left in the cell is not a file', () {
      // Would otherwise save as a live button that opens a blank page, and get
      // queued for download by the app's PDF indexer.
      expect(parseGateAssets('waiting for the key'), isEmpty);
      expect(parseGateAssets('{"Paper": "ask sir"}'), isEmpty);
      expect(parseGateAssets('{'), isEmpty);
      expect(parseGateAssets(''), isEmpty);
      expect(parseGateAssets('{}'), isEmpty);
    });

    test('unknown keys are ignored, known ones beside them still read', () {
      final assets = parseGateAssets(
        '{"Notes": "https://d/n.pdf", "Paper": "https://d/p.pdf"}',
      );
      expect(assets, hasLength(1));
      expect(assets.single.url, 'https://d/p.pdf');
    });
  });

  group('encodeGateAssets', () {
    test('one unlabelled file of a kind is written as a bare URL', () {
      final cell = encodeGateAssets(const [
        GateAsset(kind: GateAssetKind.paper, url: 'https://d/p.pdf'),
      ]);
      expect(jsonDecode(cell), {'Paper': 'https://d/p.pdf'});
    });

    test('sessions are written as a labelled list', () {
      final cell = encodeGateAssets(const [
        GateAsset(
            kind: GateAssetKind.paper, label: 'Session 1', url: 'https://d/1'),
        GateAsset(
            kind: GateAssetKind.paper, label: 'Session 2', url: 'https://d/2'),
      ]);
      expect(jsonDecode(cell), {
        'Paper': [
          {'label': 'Session 1', 'url': 'https://d/1'},
          {'label': 'Session 2', 'url': 'https://d/2'},
        ],
      });
    });

    test('nothing chosen clears the column rather than storing {}', () {
      expect(encodeGateAssets(const []), '');
    });

    test('round-trips through the parser', () {
      const assets = [
        GateAsset(
            kind: GateAssetKind.paper, label: 'Session 1', url: 'https://d/1'),
        GateAsset(
            kind: GateAssetKind.paper, label: 'Session 2', url: 'https://d/2'),
        GateAsset(kind: GateAssetKind.answerKey, url: 'https://d/k'),
        GateAsset(kind: GateAssetKind.solvedPaper, url: 'https://d/s'),
      ];
      expect(parseGateAssets(encodeGateAssets(assets)), assets);
    });
  });

  group('guessGateAssetKind', () {
    test('plain papers', () {
      expect(guessGateAssetKind('GATE_2024_CS.pdf'), GateAssetKind.paper);
      expect(guessGateAssetKind('2024 Session 1.pdf'), GateAssetKind.paper);
    });

    test('answer keys', () {
      expect(guessGateAssetKind('GATE 2024 CS answer key.pdf'),
          GateAssetKind.answerKey);
      expect(guessGateAssetKind('2024_KEY_S2.pdf'), GateAssetKind.answerKey);
    });

    test('solved papers, even when the name also says answer key', () {
      // 'Solved with answer key' is a solved paper: reading the kinds the other
      // way round would file the worked solutions under the key, where the app
      // does not index them.
      expect(guessGateAssetKind('GATE 2024 solved with answer key.pdf'),
          GateAssetKind.solvedPaper);
      expect(
          guessGateAssetKind('2024 solutions.pdf'), GateAssetKind.solvedPaper);
    });
  });

  group('the folder a file sits in', () {
    // These describe a reader, not the bucket. The year/kind tree was removed on
    // 2026-09-16, so every key below is hypothetical and every real file in the
    // bucket takes the null path and falls back to its name. Kept because a
    // tolerant reader costs nothing and a hand-made folder should still be read
    // rather than guessed at — but nothing here should be read as a description
    // of how uploads are filed.
    const branch = 'vtu/gatepyqs/AS_Aerospace_Engineering';

    test('the kind comes from the folder above the file', () {
      expect(gateKindFromKey('$branch/2024/answer_key/x.pdf'),
          GateAssetKind.answerKey);
      expect(gateKindFromKey('$branch/2024/papers/x.pdf'), GateAssetKind.paper);
      expect(gateKindFromKey('$branch/2024/solved_papers/x.pdf'),
          GateAssetKind.solvedPaper);
    });

    test('the folder beats what the file name says', () {
      // If a folder is there, someone chose to put the file in it, so it is an
      // answer key whatever it is called.
      const key = '$branch/2024/answer_key/GATE 2024 paper solved.pdf';
      expect(gateKindFromKey(key), GateAssetKind.answerKey);
      expect(guessGateAssetKind('GATE 2024 paper solved.pdf'),
          GateAssetKind.solvedPaper);
    });

    test('null for a file that is not under a kind folder', () {
      // This is what every file in the bucket hits today: GATE papers sit
      // directly in the branch folder. Null is what makes the caller fall back
      // to the name, and it is the normal answer, not the exceptional one.
      expect(gateKindFromKey('$branch/GATE 2024 paper.pdf'), isNull);
      expect(gateKindFromKey('$branch/2014.pdf'), isNull);
      expect(gateKindFromKey('$branch/2024/x.pdf'), isNull);
      expect(gateKindFromKey('x.pdf'), isNull);
    });

    test('only the folder directly above counts', () {
      // A folder called 'papers' further up must not decide the kind of a file
      // filed under answer_key.
      expect(gateKindFromKey('$branch/papers/2024/answer_key/x.pdf'),
          GateAssetKind.answerKey);
    });

    test('the year comes from a whole segment, not the file name', () {
      expect(gateYearFromKey('$branch/2024/papers/x.pdf'), 2024);
      expect(gateYearFromKey('$branch/2007/answer_key/x.pdf'), 2007);
      // The name says 2023, the folder says 2024. The folder wins.
      expect(gateYearFromKey('$branch/2024/papers/GATE 2023 paper.pdf'), 2024);
      // A year inside the file name is not a segment, so this is unfiled.
      expect(gateYearFromKey('$branch/GATE 2024 paper.pdf'), isNull);
      expect(gateYearFromKey('$branch/papers/x.pdf'), isNull);
    });
  });

  group('guessGateSessionLabel', () {
    test('the ways a session is written in a file name', () {
      expect(guessGateSessionLabel('GATE_2024_Session_1.pdf'), 'Session 1');
      expect(guessGateSessionLabel('gate 2024 shift 2.pdf'), 'Session 2');
      expect(guessGateSessionLabel('GATE-2024-S1.pdf'), 'Session 1');
      expect(guessGateSessionLabel('2024 forenoon.pdf'), 'Session 1');
      expect(guessGateSessionLabel('2024_AN.pdf'), 'Session 2');
    });

    test('no session in the name is an empty label, not a guess', () {
      // A branch with one sitting has nothing to label, and the student app only
      // numbers entries once a kind has more than one.
      expect(guessGateSessionLabel('GATE 2024 CS.pdf'), isEmpty);
      // The year is not a session number.
      expect(guessGateSessionLabel('gate2024.pdf'), isEmpty);
    });
  });

  group('gateYearIn', () {
    test('finds the exam year, or nothing', () {
      expect(gateYearIn('GATE_2024_CS.pdf'), 2024);
      expect(gateYearIn('vtu/gatepyqs/CS/2016 key.pdf'), 2016);
      expect(gateYearIn('question paper.pdf'), isNull);
    });
  });

  group('the gatepyqs catalog entry', () {
    final spec = adminCatalog.firstWhere((t) => t.table == 'gatepyqs');
    final years = [
      for (final field in spec.fields)
        if (int.tryParse(field.column) != null) field,
    ];

    test('offers every year column the database has', () {
      // 2014–2026, newest first: a year missing here cannot be filled in at all.
      expect(years, hasLength(13));
      expect(years.first.column, '2026');
      expect(years.last.column, '2014');
      expect(years.every((f) => f.type == FieldType.gateAssets), isTrue);
    });

    test('2014 is no longer NOT NULL', () {
      // docs/sql/026 dropped the constraint. While it was still declared here,
      // clearing 2014 wrote '' — which reads as a year with nothing in it, but
      // is not the same as empty.
      final field = years.firstWhere((f) => f.column == '2014');
      expect(field.notNull, isFalse);
      expect(FieldCodec.encode(field, ''), isNull);
    });
  });

  group('FieldCodec for a year column', () {
    final field = adminCatalog
        .firstWhere((t) => t.table == 'gatepyqs')
        .fields
        .firstWhere((f) => f.column == '2024');

    test('sends the cell as text, not as a decoded object', () {
      // The column is `text`. Sending a Map would have PostgREST stringify it
      // back with whatever spacing it chose.
      const cell = '{"Paper": "https://d/p.pdf"}';
      expect(FieldCodec.encode(field, cell), cell);
    });

    test('accepts what the builder writes, and a plain link', () {
      expect(FieldCodec.validate(field, ''), isNull);
      expect(FieldCodec.validate(field, '{"Paper": "https://d/p.pdf"}'), isNull);
      expect(
        FieldCodec.validate(field, 'https://drive.google.com/file/d/A/view'),
        isNull,
      );
    });

    test('refuses a cell the app would silently ignore', () {
      // The student app skips a year it cannot read, so without this the save
      // succeeds, looks saved, and shows the student nothing.
      expect(FieldCodec.validate(field, 'waiting for the key'), isNotNull);
      expect(FieldCodec.validate(field, '{"Paper": "tbd"}'), isNotNull);
      expect(FieldCodec.validate(field, '{"Paper": '), isNotNull);
    });
  });

  group('pyqpSessionLabel', () {
    test('spells a session column the way the form does', () {
      expect(pyqpSessionLabel('june_july_2025'), 'June/July 2025');
      expect(pyqpSessionLabel('dec_jan_2018'), 'Dec/Jan 2018');
    });
  });

  group('pyqpSessionMatches', () {
    // Real keys, below the subject folder: `vtu/scheme-2025/1st_year/py_qp/` is
    // stripped before this is called. Both shapes are in the bucket at once.
    test('a file named after the sitting belongs to it', () {
      const files = {
        'june_july_2025.pdf': 'june_july_2025',
        'June-July 2025 Paper A.pdf': 'june_july_2025',
        'BCS301 June July 2025.pdf': 'june_july_2025',
        // Abbreviated, as a lot of the bucket is.
        '3rd sem QP - jul 2025.pdf': 'june_july_2025',
        'DEC_JAN_2019 solved.pdf': 'dec_jan_2019',
        'BCS403 Dec 2019.pdf': 'dec_jan_2019',
      };
      for (final entry in files.entries) {
        expect(pyqpSessionMatches(entry.key, entry.value), isTrue,
            reason: entry.key);
      }
    });

    test('the session folder counts, not just the file name', () {
      // The common shape in the bucket, and the reason the path is passed rather
      // than the name: `1BCEDS103.pdf` on its own names no sitting at all.
      expect(
        pyqpSessionMatches('DEC JAN 2026/1BCEDS103.pdf', 'dec_jan_2026'),
        isTrue,
      );
      expect(
        pyqpSessionMatches('JUNE JULY 2025/1BBEE105 QP.pdf', 'june_july_2025'),
        isTrue,
      );
      // And the folder is not read as belonging to the other one either.
      expect(
        pyqpSessionMatches('DEC JAN 2026/1BCEDS103.pdf', 'june_july_2026'),
        isFalse,
      );
    });

    test('a file that says nothing at all is offered under every sitting', () {
      // `1BBEE205.pdf` sitting straight in the subject folder. Refusing to guess
      // is right — the person ticking it knows which sitting it was, and hiding
      // it is what makes a folder look empty.
      for (final session in const [
        'dec_jan_2018',
        'june_july_2025',
        'dec_jan_2027',
      ]) {
        expect(pyqpSessionMatches('1BBEE205.pdf', session), isTrue,
            reason: session);
      }
    });

    test('a file named after the other sitting in the same year is not', () {
      // The trap: both `dec_jan_2019` and `june_july_2019` carry 2019, and the
      // folder holds both, so only the months tell them apart.
      expect(pyqpSessionMatches('Dec-Jan 2019 Paper A.pdf', 'june_july_2019'),
          isFalse);
      expect(pyqpSessionMatches('June-July 2019 Paper A.pdf', 'dec_jan_2019'),
          isFalse);
      expect(pyqpSessionMatches('Dec-Jan 2019 Paper A.pdf', 'dec_jan_2019'),
          isTrue);
    });

    test('another year is not this session', () {
      expect(pyqpSessionMatches('june_july_2024.pdf', 'june_july_2025'), isFalse);
      expect(pyqpSessionMatches('JUNE JULY 2024/x.pdf', 'june_july_2025'),
          isFalse);
    });

    test('half a date is ambiguous, so it shows under both sittings', () {
      // A year with no month, and a month with no year. Neither is enough to
      // place the file, and refusing to guess shows it under both.
      expect(pyqpSessionMatches('2019 Paper A.pdf', 'dec_jan_2019'), isTrue);
      expect(pyqpSessionMatches('2019 Paper A.pdf', 'june_july_2019'), isTrue);
      expect(pyqpSessionMatches('Dec-Jan Paper A.pdf', 'dec_jan_2019'), isTrue);
      // Unless the half it does give is the other sitting's.
      expect(pyqpSessionMatches('Dec-Jan Paper A.pdf', 'june_july_2019'),
          isFalse);
    });

    test('a column that is not a session filters nothing out', () {
      expect(pyqpSessionMatches('anything.pdf', 'id'), isTrue);
    });
  });

  group('guessPaperLabel', () {
    test('the ways a paper letter is written in a file name', () {
      expect(guessPaperLabel('june_july_2025 Paper A.pdf'), 'Paper A');
      expect(guessPaperLabel('Paper B - dec jan 2019.pdf'), 'Paper B');
      expect(guessPaperLabel('BCS301 set c.pdf'), 'Paper C');
    });

    test('a name that does not say gets no label rather than a guess', () {
      // A wrong chip costs two taps and so does no chip — but only one of them
      // is wrong.
      expect(guessPaperLabel('june_july_2025.pdf'), isEmpty);
      expect(guessPaperLabel('A.pdf'), isEmpty);
    });
  });

  group('solvedLabelFor', () {
    test('says which paper it solves, and leaves anything else alone', () {
      expect(solvedLabelFor('Paper A'), 'Solved A');
      expect(solvedLabelFor(''), isEmpty);
      // GATE's session labels are not paper labels and must not be mangled.
      expect(solvedLabelFor('Session 1'), 'Session 1');
    });
  });

  group('the py_qp catalog entry', () {
    final spec = adminCatalog.firstWhere((t) => t.table == 'py_qp');
    final sessions = [
      for (final field in spec.fields)
        if (pyqpSessionColumns.contains(field.column)) field,
    ];

    test('every session column is the same JSON editor as a GATE year', () {
      // A single `fileUrl` here would write a bare URL, which the student app
      // reads as one paper — so Paper B and C could not be entered at all.
      expect(sessions, hasLength(pyqpSessionColumns.length));
      expect(sessions.every((f) => f.type == FieldType.gateAssets), isTrue);
      expect(
        sessions.every((f) => f.bucketFolder == BucketFolder.questionPaper),
        isTrue,
      );
    });

    test('the session fields run newest first', () {
      // The form renders fields in the order the catalog declares them and adds
      // no sort of its own, so this list is literally the order an admin scrolls.
      // Newest at the top is the whole point of it.
      expect(sessions.first.column, 'june_july_2027');
      expect(sessions.last.column, 'dec_jan_2018');
    });

    test('the picker can tell a session column from a GATE year', () {
      // This is what the editor branches on to pass a session instead of a
      // year: swap the folder and the session columns silently become years.
      final gateField = adminCatalog
          .firstWhere((t) => t.table == 'gatepyqs')
          .fields
          .firstWhere((f) => f.column == '2024');
      expect(gateField.bucketFolder, BucketFolder.gatePaper);
    });

    test('accepts and refuses the same cells a year column does', () {
      final field = sessions.first;
      expect(FieldCodec.validate(field, ''), isNull);
      expect(
        FieldCodec.validate(
          field,
          '{"Paper": [{"label": "Paper A", "url": "https://d/a.pdf"}], '
          '"Solved Papers": "https://d/s.pdf"}',
        ),
        isNull,
      );
      expect(FieldCodec.validate(field, 'waiting for the key'), isNotNull);
    });
  });
}
