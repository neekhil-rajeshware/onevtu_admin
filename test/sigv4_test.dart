import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/r2/sigv4.dart';

void main() {
  group('canonical encoding', () {
    test('leaves the RFC 3986 unreserved set alone', () {
      expect(
        SigV4Signer.encode('AZaz09-._~'),
        'AZaz09-._~',
      );
    });

    test('encodes the characters that actually break R2 signatures', () {
      // A space must be %20, never `+`, and `+` itself must be escaped — getting
      // either wrong is the classic silent SignatureDoesNotMatch.
      expect(SigV4Signer.encode('a b'), 'a%20b');
      expect(SigV4Signer.encode('a+b'), 'a%2Bb');
      expect(SigV4Signer.encode('a=b&c'), 'a%3Db%26c');
    });

    test('encodes slashes unless asked not to', () {
      expect(SigV4Signer.encode('syllabus/cs.pdf'), 'syllabus%2Fcs.pdf');
      expect(
        SigV4Signer.encode('syllabus/cs.pdf', encodeSlash: false),
        'syllabus/cs.pdf',
      );
    });

    test('encodes non-ASCII as UTF-8 bytes', () {
      expect(SigV4Signer.encode('ಕನ್ನಡ').startsWith('%E0%B2%95'), isTrue);
    });
  });

  group('sha256Hex', () {
    test('matches the published empty-string digest', () {
      expect(SigV4Signer.sha256Hex(const []), SigV4Signer.emptyPayloadSha256);
    });

    test('matches the FIPS 180-2 vector for "abc"', () {
      expect(
        SigV4Signer.sha256Hex('abc'.codeUnits),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('canonicalQuery', () {
    test('sorts and encodes, and is empty for no params', () {
      expect(SigV4Signer.canonicalQuery(const {}), '');
      expect(
        SigV4Signer.canonicalQuery({
          'prefix': 'syllabus/2022 scheme',
          'list-type': '2',
          'delimiter': '/',
        }),
        'delimiter=%2F&list-type=2&prefix=syllabus%2F2022%20scheme',
      );
    });
  });

  group('sign', () {
    const signer = SigV4Signer(
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    );
    final at = DateTime.utc(2026, 8, 29, 10, 45);

    Map<String, String> signOnce({
      String method = 'GET',
      String path = '/vtu-resources',
      Map<String, String> query = const {'list-type': '2'},
      String payload = SigV4Signer.emptyPayloadSha256,
      SigV4Signer using = signer,
    }) {
      return using.sign(
        method: method,
        host: 'abc123.r2.cloudflarestorage.com',
        canonicalPath: path,
        query: query,
        payloadSha256: payload,
        now: at,
      );
    }

    test('sends the headers R2 requires', () {
      final headers = signOnce();
      expect(headers['x-amz-date'], '20260829T104500Z');
      expect(headers['x-amz-content-sha256'], SigV4Signer.emptyPayloadSha256);
      expect(headers['host'], 'abc123.r2.cloudflarestorage.com');
    });

    test('scopes the credential to the date, region and service', () {
      final auth = signOnce()['authorization']!;
      expect(auth, startsWith('AWS4-HMAC-SHA256 '));
      expect(
        auth,
        contains('Credential=AKIDEXAMPLE/20260829/auto/s3/aws4_request'),
      );
      // Sorted, and the three headers that are always signed.
      expect(
        auth,
        contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'),
      );
    });

    test('is deterministic for identical input', () {
      expect(signOnce()['authorization'], signOnce()['authorization']);
    });

    test('changes when anything that is signed changes', () {
      final base = signOnce()['authorization'];

      expect(signOnce(method: 'PUT')['authorization'], isNot(base));
      expect(signOnce(path: '/vtu-resources/a.pdf')['authorization'],
          isNot(base));
      expect(signOnce(query: const {'list-type': '1'})['authorization'],
          isNot(base));
      expect(signOnce(payload: SigV4Signer.sha256Hex([1, 2, 3]))['authorization'],
          isNot(base));
      expect(
        signOnce(
          using: const SigV4Signer(
            accessKeyId: 'AKIDEXAMPLE',
            secretAccessKey: 'a-different-secret',
          ),
        )['authorization'],
        isNot(base),
      );
    });

    test('signs extra headers that are passed in', () {
      final auth = signOnce(
        method: 'PUT',
      );
      final withType = signer.sign(
        method: 'PUT',
        host: 'abc123.r2.cloudflarestorage.com',
        canonicalPath: '/vtu-resources',
        query: const {'list-type': '2'},
        headers: const {'Content-Type': 'application/pdf'},
        now: at,
      );
      expect(withType['authorization'], contains('content-type'));
      expect(withType['authorization'], isNot(auth['authorization']));
    });
  });
}
