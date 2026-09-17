import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onevtu_admin/r2/r2_client.dart';
import 'package:onevtu_admin/r2/r2_credentials.dart';

const _credentials = R2Credentials(
  accountId: 'abc123',
  accessKeyId: 'key-id',
  secretAccessKey: 'secret',
  bucket: 'vtu-resources',
  publicBaseUrl: 'https://pub-test.r2.dev',
);

const _listingXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>tok-2</NextContinuationToken>
  <CommonPrefixes><Prefix>syllabus/</Prefix></CommonPrefixes>
  <CommonPrefixes><Prefix>pyqp/</Prefix></CommonPrefixes>
  <Contents>
    <Key>syllabus/cs.pdf</Key>
    <Size>2097152</Size>
    <LastModified>2026-08-01T10:00:00.000Z</LastModified>
    <ETag>"abc"</ETag>
  </Contents>
  <Contents>
    <Key>emptyfolder/</Key>
    <Size>0</Size>
    <LastModified>2026-08-01T10:00:00.000Z</LastModified>
  </Contents>
</ListBucketResult>
''';

void main() {
  group('list', () {
    test('parses folders, files and the continuation token', () async {
      late http.Request seen;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(_listingXml, 200);
        }),
      );

      final listing = await client.list(prefix: 'x/');

      // Path-style addressing: the bucket is the first path segment.
      expect(seen.url.path, '/vtu-resources');
      expect(seen.url.queryParameters['list-type'], '2');
      expect(seen.url.queryParameters['prefix'], 'x/');
      expect(seen.url.queryParameters['delimiter'], '/');
      expect(seen.headers['authorization'], contains('AWS4-HMAC-SHA256'));

      expect(listing.prefixes, ['pyqp/', 'syllabus/']); // sorted
      // A key ending in `/` is a folder placeholder, not a file.
      expect(listing.objects.map((o) => o.key), ['syllabus/cs.pdf']);
      expect(listing.objects.single.name, 'cs.pdf');
      expect(listing.objects.single.readableSize, '2.0 MB');
      expect(listing.objects.single.etag, 'abc');
      expect(listing.nextToken, 'tok-2');
      client.dispose();
    });

    test('passes the continuation token on for the next page', () async {
      late Uri url;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          url = request.url;
          return http.Response(_listingXml, 200);
        }),
      );

      await client.list(continuationToken: 'tok-2');
      expect(url.queryParameters['continuation-token'], 'tok-2');
      client.dispose();
    });
  });

  group('put', () {
    test('signs the same encoded path it requests', () async {
      late http.Request seen;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await client.put(
        key: 'syllabus/2022 scheme/cs.pdf',
        bytes: Uint8List.fromList(utf8.encode('hello')),
        contentType: 'application/pdf',
      );

      // The space is %20 in the URL, and `/` still separates segments — if the
      // signed string and the URI ever diverge here, R2 answers 403.
      expect(
        seen.url.toString(),
        'https://abc123.r2.cloudflarestorage.com'
            '/vtu-resources/syllabus/2022%20scheme/cs.pdf',
      );
      expect(seen.headers['content-type'], 'application/pdf');
      // Payload is hashed, not sent as UNSIGNED-PAYLOAD.
      expect(seen.headers['x-amz-content-sha256'], hasLength(64));
      expect(seen.headers['x-amz-content-sha256'],
          isNot('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
      client.dispose();
    });
  });

  group('copy', () {
    test('names the source in the header and the target in the URL', () async {
      late http.Request seen;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await client.copy(
        from: 'syllabus/2022 scheme/cs.pdf',
        to: 'deleted_old_files/2026-08-31_1432/syllabus/2022 scheme/cs.pdf',
      );

      expect(seen.method, 'PUT');
      expect(
        seen.url.path,
        '/vtu-resources/deleted_old_files/2026-08-31_1432'
            '/syllabus/2022%20scheme/cs.pdf',
      );
      // The source is bucket-qualified and encoded the same way, with the slashes
      // left alone — an unencoded space here is a 403.
      expect(seen.headers['x-amz-copy-source'],
          '/vtu-resources/syllabus/2022%20scheme/cs.pdf');
      client.dispose();
    });

    test('does not mistake a 200 with an error body for a copy', () async {
      // S3 holds the connection open while it copies, so a CopyObject failure
      // arrives as 200 + XML. Believing it would archive nothing and then delete.
      final client = R2Client(
        _credentials,
        httpClient: MockClient((_) async => http.Response(
              '<?xml version="1.0"?><Error><Code>InternalError</Code>'
              '<Message>try again</Message></Error>',
              200,
            )),
      );

      await expectLater(
        client.copy(from: 'a.pdf', to: 'b.pdf'),
        throwsA(isA<R2Exception>()),
      );
      client.dispose();
    });
  });

  group('exists', () {
    test('is false on 404 and true on 200', () async {
      var status = 404;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((_) async => http.Response('', status)),
      );

      expect(await client.exists('a.pdf'), isFalse);
      status = 200;
      expect(await client.exists('a.pdf'), isTrue);
      client.dispose();
    });
  });

  group('folders', () {
    test('are created as the zero-byte marker every S3 console writes',
        () async {
      late http.Request seen;
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await client.createFolder('syllabus/2026');

      // The trailing slash is the whole trick — without it this is a file named
      // "2026", and an empty folder cannot exist in S3 at all.
      expect(seen.url.path, '/vtu-resources/syllabus/2026/');
      expect(seen.method, 'PUT');
      expect(seen.bodyBytes, isEmpty);
      client.dispose();
    });

    test('a marker is hidden from a listing but visible to a delete', () async {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <Contents><Key>syllabus/</Key><Size>0</Size></Contents>
  <Contents><Key>syllabus/cs.pdf</Key><Size>10</Size></Contents>
</ListBucketResult>
''';
      final client = R2Client(
        _credentials,
        httpClient: MockClient((_) async => http.Response(xml, 200)),
      );

      final browsing = await client.list(prefix: 'syllabus/');
      expect(browsing.objects.map((o) => o.key), ['syllabus/cs.pdf']);

      // A recursive delete that skipped the marker would leave the folder on
      // screen with nothing in it.
      final everything = await client.objectsUnder('syllabus/');
      expect(everything.map((o) => o.key), ['syllabus/', 'syllabus/cs.pdf']);
      client.dispose();
    });

    test('objectsUnder walks every page, not just the first', () async {
      const firstPage = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>tok-2</NextContinuationToken>
  <Contents><Key>a/1.pdf</Key><Size>1</Size></Contents>
</ListBucketResult>
''';
      const lastPage = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>false</IsTruncated>
  <Contents><Key>a/2.pdf</Key><Size>1</Size></Contents>
</ListBucketResult>
''';
      final tokens = <String?>[];
      final client = R2Client(
        _credentials,
        httpClient: MockClient((request) async {
          final token = request.url.queryParameters['continuation-token'];
          tokens.add(token);
          // A folder delete that stopped at page one would report success having
          // left 800 files behind.
          return http.Response(token == null ? firstPage : lastPage, 200);
        }),
      );

      final all = await client.objectsUnder('a/');
      expect(all.map((o) => o.key), ['a/1.pdf', 'a/2.pdf']);
      expect(tokens, [null, 'tok-2']);
      client.dispose();
    });
  });

  group('errors', () {
    Future<R2Exception> failWith(String code, int status) async {
      final client = R2Client(
        _credentials,
        httpClient: MockClient((_) async => http.Response(
              '<Error><Code>$code</Code><Message>nope</Message></Error>',
              status,
            )),
      );
      try {
        await client.list();
        fail('expected an R2Exception');
      } on R2Exception catch (error) {
        return error;
      } finally {
        client.dispose();
      }
    }

    test('turns a bad secret into an instruction', () async {
      final error = await failWith('SignatureDoesNotMatch', 403);
      expect('$error', contains('secret access key'));
    });

    test('turns a read-only token into an instruction', () async {
      final error = await failWith('AccessDenied', 403);
      expect('$error', contains('Object Read & Write'));
    });

    test('falls back to the message for anything unrecognised', () async {
      final error = await failWith('SomethingElse', 500);
      expect('$error', 'nope (HTTP 500)');
    });

    test('survives a non-XML body', () async {
      final client = R2Client(
        _credentials,
        httpClient: MockClient((_) async => http.Response('gateway down', 502)),
      );
      await expectLater(client.list(), throwsA(isA<R2Exception>()));
      client.dispose();
    });
  });

  group('public URLs', () {
    test('round-trips a key through the public base', () {
      expect(
        _credentials.publicUrlFor('syllabus/cs.pdf'),
        'https://pub-test.r2.dev/syllabus/cs.pdf',
      );
      expect(
        _credentials.keyForPublicUrl('https://pub-test.r2.dev/syllabus/cs.pdf'),
        'syllabus/cs.pdf',
      );
    });

    test('encodes a key with spaces, and reads that URL back', () {
      // The bucket's keys have spaces and capitals, and the links already in the
      // database carry them as %20. Getting this wrong is not cosmetic: the key
      // computed off a link is what a replace archives, and a key still holding
      // %20 gets signed as %2520, HEADs 404, archives nothing, and leaves a
      // duplicate object behind with a broken link in the row.
      const key = 'vtu/scheme-2025/1st_year/1BMATC101 Calculus.pdf';
      const url =
          'https://pub-test.r2.dev/vtu/scheme-2025/1st_year/1BMATC101%20Calculus.pdf';

      expect(_credentials.publicUrlFor(key), url);
      expect(_credentials.keyForPublicUrl(url), key);
    });

    test('leaves the slashes alone, because they are the folders', () {
      expect(
        _credentials.publicUrlFor('vtu/gatepyqs/AE_Aeronautical_Engineering/2014.pdf'),
        'https://pub-test.r2.dev/vtu/gatepyqs/AE_Aeronautical_Engineering/2014.pdf',
      );
    });

    test('gives back a key even when the URL is not properly encoded', () {
      // A link pasted or typed by hand: a bare '%' cannot be decoded, and
      // guessing at the key beats throwing while somebody is saving a row.
      expect(
        _credentials.keyForPublicUrl('https://pub-test.r2.dev/vtu/100%.pdf'),
        'vtu/100%.pdf',
      );
    });

    test('tolerates a trailing slash on the base and a leading one on the key',
        () {
      const trailing = R2Credentials(publicBaseUrl: 'https://pub-test.r2.dev/');
      expect(trailing.publicUrlFor('/a.pdf'), 'https://pub-test.r2.dev/a.pdf');
    });

    test('returns null for a URL on some other host', () {
      expect(_credentials.keyForPublicUrl('https://example.com/a.pdf'), isNull);
    });

    test('is incomplete until every credential is set', () {
      expect(const R2Credentials().isComplete, isFalse);
      expect(_credentials.isComplete, isTrue);
      expect(_credentials.endpointHost, 'abc123.r2.cloudflarestorage.com');
    });
  });
}
