import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onevtu_admin/r2/archive.dart';
import 'package:onevtu_admin/r2/r2_client.dart';
import 'package:onevtu_admin/r2/r2_credentials.dart';

/// Replacing a file is the one operation in this app that can destroy something
/// irreversibly: the bucket has no versioning, the link is already in the
/// database, and the students' copy of the app follows it. What makes it safe is
/// purely the *order* of four requests, which is what these tests pin.
const _credentials = R2Credentials(
  accountId: 'abc123',
  accessKeyId: 'key-id',
  secretAccessKey: 'secret',
  bucket: 'vtu-resources',
  publicBaseUrl: 'https://pub-test.r2.dev',
);

/// Real keys, spaces and capitals included — that is the bucket's convention, and
/// it is what makes the round trip through URL encoding worth exercising here.
const _year = 'vtu/scheme-2025/1st_year';
const _sem = 'vtu/scheme-2025/AE_Aeronautical_Engineering/3rd_sem';

final _when = DateTime(2026, 8, 31, 14, 32, 5);
final _bytes = Uint8List.fromList(utf8.encode('a new syllabus'));

/// Records every request as `METHOD key` — plus `<- source` for a copy — with the
/// bucket prefix and percent-encoding undone, so a failure reads like a story.
class _Bucket {
  _Bucket(this.present);

  final Set<String> present;
  final List<String> log = [];

  R2Client get client => R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          final key = _keyOf(request.url.path);
          final source = request.headers['x-amz-copy-source'];
          log.add([
            request.method,
            key,
            if (source != null) '<- ${_keyOf(Uri.decodeFull(source))}',
          ].join(' '));

          switch (request.method) {
            case 'HEAD':
              return http.Response('', present.contains(key) ? 200 : 404);
            case 'DELETE':
              present.remove(key);
              return http.Response('', 204);
            default:
              present.add(key);
              return http.Response('', 200);
          }
        }),
      );

  static String _keyOf(String path) =>
      Uri.decodeFull(path).replaceFirst('/vtu-resources/', '');
}

void main() {
  // The bin belongs to the level, not to the bucket — see `bucket_layout.dart`.
  const stamp = '2026-08-31_143205';
  const yearBin = '$_year/deleted_old_files/$stamp';
  const semBin = '$_sem/deleted_old_files/$stamp';

  group('replacing a file in place', () {
    test('copies it into its own level\'s archive before overwriting it',
        () async {
      const key = '$_year/1BMATC101 Calculus.pdf';
      final bucket = _Bucket({key});

      final archived = await writeWithArchive(
        bucket.client,
        key: key,
        bytes: _bytes,
        contentType: 'application/pdf',
        replacing: key,
        at: _when,
      );

      expect(bucket.log, [
        'HEAD $key',
        'PUT $yearBin/1BMATC101 Calculus.pdf <- $key',
        'PUT $key',
      ]);
      // No DELETE: the PUT is the replacement, and deleting the key it just
      // wrote would leave the link pointing at nothing.
      expect(bucket.log.where((r) => r.startsWith('DELETE')), isEmpty);
      expect(archived, ['$yearBin/1BMATC101 Calculus.pdf']);
    });

    test('archives a paper under the path it had below its semester', () async {
      const key = '$_sem/py_qp/1BAE305 UAV Systems/june_july_2025.pdf';
      final bucket = _Bucket({key});

      await writeWithArchive(
        bucket.client,
        key: key,
        bytes: _bytes,
        contentType: 'application/pdf',
        replacing: key,
        at: _when,
      );

      expect(bucket.log, [
        'HEAD $key',
        'PUT $semBin/py_qp/1BAE305 UAV Systems/june_july_2025.pdf <- $key',
        'PUT $key',
      ]);
    });
  });

  group('replacing a file under a new name', () {
    test('archives the old one, uploads, then removes the old one', () async {
      final bucket = _Bucket({'$_year/old.pdf'});

      await writeWithArchive(
        bucket.client,
        key: '$_year/1BMATC101 Calculus.pdf',
        bytes: _bytes,
        contentType: 'application/pdf',
        replacing: '$_year/old.pdf',
        at: _when,
      );

      expect(bucket.log, [
        'HEAD $_year/old.pdf',
        'PUT $yearBin/old.pdf <- $_year/old.pdf',
        'HEAD $_year/1BMATC101 Calculus.pdf', // free, so nothing to keep there
        'PUT $_year/1BMATC101 Calculus.pdf',
        // Last, and only once the new file is really up.
        'DELETE $_year/old.pdf',
      ]);
      expect(bucket.present,
          {'$_year/1BMATC101 Calculus.pdf', '$yearBin/old.pdf'});
    });

    test('also keeps an unrelated file already sitting at the new name',
        () async {
      final bucket = _Bucket({'$_year/old.pdf', '$_year/new.pdf'});

      final archived = await writeWithArchive(
        bucket.client,
        key: '$_year/new.pdf',
        bytes: _bytes,
        contentType: 'application/pdf',
        replacing: '$_year/old.pdf',
        at: _when,
      );

      expect(archived, ['$yearBin/old.pdf', '$yearBin/new.pdf']);
    });
  });

  group('a fresh upload', () {
    test('archives nothing when the key is free', () async {
      final bucket = _Bucket({});

      final archived = await writeWithArchive(
        bucket.client,
        key: '$_year/cs.pdf',
        bytes: _bytes,
        contentType: 'application/pdf',
        at: _when,
      );

      expect(bucket.log, ['HEAD $_year/cs.pdf', 'PUT $_year/cs.pdf']);
      expect(archived, isEmpty);
    });

    test('still keeps whatever it would overwrite, with no row to replace',
        () async {
      // The bucket screen's own Replace: no column involved, so `replacing` is
      // null, and the file being overwritten still has to survive.
      final bucket = _Bucket({'$_year/cs.pdf'});

      final archived = await writeWithArchive(
        bucket.client,
        key: '$_year/cs.pdf',
        bytes: _bytes,
        contentType: 'application/pdf',
        at: _when,
      );

      expect(archived, ['$yearBin/cs.pdf']);
    });
  });

  group('deleting to the archive', () {
    test('copies each file out before removing it', () async {
      final bucket = _Bucket({'$_year/a.pdf', '$_year/b.pdf'});

      final count = await archiveAndDelete(
        bucket.client,
        keys: ['$_year/a.pdf', '$_year/b.pdf'],
        at: _when,
      );

      expect(count, 2);
      expect(bucket.log, [
        'PUT $yearBin/a.pdf <- $_year/a.pdf',
        'DELETE $_year/a.pdf',
        'PUT $yearBin/b.pdf <- $_year/b.pdf',
        'DELETE $_year/b.pdf',
      ]);
      // The whole folder is in the archive under one stamp, shaped as it was.
      expect(bucket.present, {'$yearBin/a.pdf', '$yearBin/b.pdf'});
    });

    test('sends each level\'s files to that level\'s own bin', () async {
      // One delete can span levels — the picker selects across a folder — and
      // each file still stays with the semester it belongs to.
      final bucket = _Bucket({'$_year/a.pdf', '$_sem/py_qp/b.pdf'});

      await archiveAndDelete(
        bucket.client,
        keys: ['$_year/a.pdf', '$_sem/py_qp/b.pdf'],
        at: _when,
      );

      expect(bucket.present, {'$yearBin/a.pdf', '$semBin/py_qp/b.pdf'});
    });

    test('a folder marker is dropped without a copy', () async {
      // Nothing is in a zero-byte placeholder, so archiving one would only put an
      // empty folder in the recycle bin.
      final bucket = _Bucket({'$_year/py_qp/'});

      await archiveAndDelete(bucket.client, keys: ['$_year/py_qp/'], at: _when);

      expect(bucket.log, ['DELETE $_year/py_qp/']);
    });

    test('emptying an archive is permanent, not another copy', () async {
      // Otherwise the recycle bin could never be emptied — every delete would
      // put the file straight back into it under a new stamp.
      final bucket = _Bucket({'$yearBin/a.pdf'});

      await archiveAndDelete(bucket.client, keys: ['$yearBin/a.pdf'], at: _when);

      expect(bucket.log, ['DELETE $yearBin/a.pdf']);
      expect(bucket.present, isEmpty);
    });

    test('stops on the first failure with the rest untouched', () async {
      var copies = 0;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          if (request.method == 'DELETE') return http.Response('', 204);
          if (++copies == 2) return http.Response('', 500);
          return http.Response('', 200);
        }),
      );

      // Deleting half a folder is bad; deleting half a folder and reporting
      // success is worse.
      await expectLater(
        archiveAndDelete(
          client,
          keys: ['$_year/a.pdf', '$_year/b.pdf', '$_year/c.pdf'],
          at: _when,
        ),
        throwsA(isA<R2Exception>()),
      );
      expect(copies, 2, reason: 'c.pdf was never reached');
      client.dispose();
    });
  });

  group('when something goes wrong', () {
    test('a failed upload leaves the old file where the database expects it',
        () async {
      var puts = 0;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          if (request.method == 'HEAD') return http.Response('', 200);
          if (request.method == 'DELETE') fail('deleted before the upload landed');
          // The archive copy succeeds, the real upload does not.
          return http.Response('', ++puts == 1 ? 200 : 500);
        }),
      );

      await expectLater(
        writeWithArchive(
          client,
          key: '$_year/new.pdf',
          bytes: _bytes,
          contentType: 'application/pdf',
          replacing: '$_year/old.pdf',
          at: _when,
        ),
        throwsA(isA<R2Exception>()),
      );
      client.dispose();
    });

    test('a failed archive copy stops before anything is written', () async {
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          if (request.method == 'HEAD') return http.Response('', 200);
          expect(request.headers['x-amz-copy-source'], isNotNull,
              reason: 'nothing may be written once the archive copy failed');
          return http.Response(
            '<Error><Code>AccessDenied</Code><Message>no</Message></Error>',
            403,
          );
        }),
      );

      await expectLater(
        writeWithArchive(
          client,
          key: '$_year/cs.pdf',
          bytes: _bytes,
          contentType: 'application/pdf',
          replacing: '$_year/cs.pdf',
          at: _when,
        ),
        throwsA(isA<R2Exception>()),
      );
      client.dispose();
    });
  });
}
