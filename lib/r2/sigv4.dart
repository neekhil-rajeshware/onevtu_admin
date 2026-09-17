import 'dart:convert';

import 'package:crypto/crypto.dart';

/// AWS Signature Version 4, the auth scheme Cloudflare R2's S3-compatible API
/// speaks. Hand-rolled because the AWS SDKs pull a very large dependency tree
/// for the four operations this app needs (list, put, get, delete).
///
/// Two details are worth knowing before touching this:
///  * the canonical path must be percent-encoded by *these* rules (RFC 3986
///    unreserved set only), which is stricter than `Uri`'s. So the caller signs
///    the same string it puts on the wire — see [R2Client] — or the signature
///    silently mismatches with a 403 `SignatureDoesNotMatch`.
///  * R2 requires `x-amz-content-sha256`, so the payload is hashed in full
///    rather than sent as UNSIGNED-PAYLOAD.
class SigV4Signer {
  const SigV4Signer({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.region = 'auto',
    this.service = 's3',
  });

  final String accessKeyId;
  final String secretAccessKey;

  /// R2 ignores the region but still signs with one; `auto` is what Cloudflare
  /// documents.
  final String region;
  final String service;

  static const String emptyPayloadSha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// Percent-encodes to the SigV4 canonical rules: everything except the RFC
  /// 3986 unreserved set, with `/` optionally preserved for path segments.
  static String encode(String value, {bool encodeSlash = true}) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      if (byte < 128 && unreserved.contains(char)) {
        out.write(char);
      } else if (char == '/' && !encodeSlash) {
        out.write(char);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// Builds `?a=b&c=d` sorted and encoded the way the signature expects, so the
  /// caller can reuse the exact same string for the request URL.
  static String canonicalQuery(Map<String, String> query) {
    if (query.isEmpty) return '';
    final pairs = query.entries
        .map((e) => '${encode(e.key)}=${encode(e.value)}')
        .toList()
      ..sort();
    return pairs.join('&');
  }

  /// Returns the headers to send, including `Authorization`.
  ///
  /// [canonicalPath] must already be encoded (leading `/`, `/` between
  /// segments) and [query] must be the same map handed to [canonicalQuery].
  Map<String, String> sign({
    required String method,
    required String host,
    required String canonicalPath,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    String payloadSha256 = emptyPayloadSha256,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final amzDate = _amzDate(timestamp);
    final dateStamp = amzDate.substring(0, 8);

    final signed = <String, String>{
      for (final entry in headers.entries)
        entry.key.toLowerCase(): entry.value.trim(),
      'host': host,
      'x-amz-content-sha256': payloadSha256,
      'x-amz-date': amzDate,
    };

    final names = signed.keys.toList()..sort();
    final canonicalHeaders =
        names.map((name) => '$name:${signed[name]}\n').join();
    final signedHeaders = names.join(';');

    final canonicalRequest = [
      method.toUpperCase(),
      canonicalPath,
      canonicalQuery(query),
      canonicalHeaders,
      signedHeaders,
      payloadSha256,
    ].join('\n');

    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    // Explicitly List<int>: `utf8.encode` gives a Uint8List, and the derived
    // keys that replace it are plain byte lists.
    List<int> key = utf8.encode('AWS4$secretAccessKey');
    for (final part in [dateStamp, region, service, 'aws4_request']) {
      key = _hmac(key, part);
    }
    final signature = _hex(_hmac(key, stringToSign));

    return {
      ...signed,
      'authorization': 'AWS4-HMAC-SHA256 '
          'Credential=$accessKeyId/$scope, '
          'SignedHeaders=$signedHeaders, '
          'Signature=$signature',
    };
  }

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// `20260829T104500Z` — SigV4 wants basic-format ISO 8601, no separators.
  static String _amzDate(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }
}
