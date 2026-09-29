import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/data/admin_repository.dart';

/// Reading `admin_analytics()`'s jsonb.
///
/// The payload below is not invented — it is what the live function returned on
/// 2026-09-29, trimmed to the interesting parts. That matters, because this is a
/// handshake between SQL in `docs/sql/041_admin_analytics.sql` and a parser in
/// Dart, and the failure mode is the quiet one: rename `filled` on either side
/// and nothing errors, the screen just draws zeroes. A hand-written fixture would
/// agree with a renamed key and prove nothing.
void main() {
  /// The real shape, all six link bars and five dimensions.
  Map<String, dynamic> payload() => {
        'users': {
          'total': 18,
          'complete': 18,
          'bars': {
            'branch': [
              {'count': 6, 'label': 'Computer Science & Engineering'},
              {'count': 4, 'label': 'Electronics & Communication Engineering'},
              {'count': 1, 'label': 'Cs'},
            ],
            'semester': [
              {'count': 8, 'label': '1'},
              {'count': 4, 'label': '8'},
            ],
            'scheme': [
              {'count': 8, 'label': '1'},
            ],
            'cycle': [
              {'count': 6, 'label': 'Physics Cycle'},
            ],
            'college': [
              {'count': 2, 'label': 'R.V.COLLEGE OF ENGINEERING'},
              {'count': 1, 'label': 'SJB INSTITUTE OF TECHNOLOGY'},
            ],
          },
        },
        'links': [
          {
            'label': 'Subjects',
            'total': 221,
            'detail': 'syllabus PDF',
            'filled': 191,
          },
          {
            'label': 'Question papers',
            'total': 205,
            'detail': 'subjects with at least one paper',
            'filled': 46,
          },
          {
            'label': 'Question papers',
            'total': 4100,
            'detail': 'papers across every exam session',
            'filled': 69,
          },
          {
            'label': 'GATE papers',
            'total': 50,
            'detail': 'branches with at least one paper',
            'filled': 29,
          },
          {
            'label': 'GATE papers',
            'total': 650,
            'detail': 'papers across every year',
            'filled': 304,
          },
          {
            'label': 'Resources',
            'total': 0,
            'detail': 'study material files',
            'filled': 0,
          },
        ],
      };

  group('the payload', () {
    test('reads the headline numbers', () {
      final data = parseAnalytics(payload());

      expect(data.users, 18);
      expect(data.completeProfiles, 18);
      expect(data.links, hasLength(6));
    });

    test('a link bar is filled out of its own total', () {
      final subjects = parseAnalytics(payload()).links.first;

      expect(subjects.label, 'Subjects');
      expect(subjects.detail, 'syllabus PDF');
      expect(subjects.value, 191);
      expect(subjects.cap, 221);
    });

    test('a session bar keeps a total far larger than its value', () {
      // The line worth pinning: "69 of 4100" is the shape of a nearly empty
      // library, and it is the number that would be lost first if a cap were
      // ever borrowed from somewhere else.
      final sessions = parseAnalytics(payload()).links[2];

      expect(sessions.value, 69);
      expect(sessions.cap, 4100);
    });

    test('a user bar is a share of everyone, not of its own dimension', () {
      final data = parseAnalytics(payload());
      final branches = data.usersBy['branch']!;

      expect(branches.first.label, 'Computer Science & Engineering');
      expect(branches.first.value, 6);
      // Not 6 — the bar is "6 of the 18 users", so it is drawn a third full.
      expect(branches.first.cap, 18);
    });

    test('user bars carry no detail line, link bars do', () {
      final data = parseAnalytics(payload());

      expect(data.usersBy['branch']!.first.detail, isEmpty);
      expect(data.links.first.detail, 'syllabus PDF');
    });

    test('every dimension the function returns survives', () {
      final data = parseAnalytics(payload());

      expect(
        data.usersBy.keys,
        containsAll(['branch', 'semester', 'scheme', 'cycle', 'college']),
      );
    });

    test('a dimension nobody has yet is an empty list, not a missing key', () {
      // `cycle` is empty while every student is between cycles; the screen skips
      // the heading for it, which it can only do if the key is there.
      final data = parseAnalytics({
        'users': {
          'total': 3,
          'complete': 1,
          'bars': {'cycle': <Object>[]},
        },
        'links': <Object>[],
      });

      expect(data.usersBy['cycle'], isEmpty);
      expect(data.users, 3);
      expect(data.completeProfiles, 1);
      expect(data.links, isEmpty);
    });
  });

  group('a payload that is not the one expected', () {
    test('nothing at all reads as nothing, rather than throwing', () {
      // The station between an app build and its migration: the RPC answers with
      // an error, and a screen that crashes on the way to saying so is worse than
      // one showing zeroes.
      final data = parseAnalytics(null);

      expect(data.users, 0);
      expect(data.completeProfiles, 0);
      expect(data.usersBy, isEmpty);
      expect(data.links, isEmpty);
    });

    test('a renamed key costs one bar, not the screen', () {
      // What a drift between the SQL and this parser actually looks like.
      final data = parseAnalytics({
        'users': {'total': 5, 'complete': 5, 'bars': {}},
        'links': [
          {'label': 'Subjects', 'total': 10, 'filled': 4},
          {'label': 'Subjects', 'papers': 4, 'total': 10},
        ],
      });

      expect(data.links, hasLength(2));
      expect(data.links.first.value, 4);
      // `papers` is not a key this reads, so that bar draws an honest zero
      // instead of the screen failing.
      expect(data.links.last.value, 0);
      expect(data.links.last.cap, 10);
    });

    test('numbers that come back quoted still count', () {
      // The client's jsonb decoder hands back ints. A future PostgREST that
      // quotes them should not turn every bar into a zero.
      final data = parseAnalytics({
        'users': {'total': '18', 'complete': '17', 'bars': {}},
        'links': [
          {'label': 'Subjects', 'total': '221', 'filled': '191'},
        ],
      });

      expect(data.users, 18);
      expect(data.completeProfiles, 17);
      expect(data.links.single.value, 191);
      expect(data.links.single.cap, 221);
    });
  });
}
