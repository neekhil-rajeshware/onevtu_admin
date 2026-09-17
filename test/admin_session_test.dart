import 'package:flutter_test/flutter_test.dart';
import 'package:onevtu_admin/core/admin_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sign-in has two steps and four ways to fail, and Supabase describes all of
/// them to a developer rather than to the person holding the phone. These are the
/// substitutions — if one stops matching, the screen goes back to showing
/// "Invalid TOTP code entered".
void main() {
  group('describeAuthFailure', () {
    test('a wrong password is not phrased as a credential problem', () {
      expect(
        describeAuthFailure(const AuthException('Invalid login credentials')),
        'That email and password do not match.',
      );
    });

    test('a wrong code says codes expire, which is the usual cause', () {
      final text =
          describeAuthFailure(const AuthException('Invalid TOTP code entered'));
      expect(text, contains('30 seconds'));
      expect(text, isNot(contains('TOTP')));
    });

    test('too many tries says how long to wait', () {
      expect(
        describeAuthFailure(
            const AuthException('Request rate limit reached', statusCode: '429')),
        contains('Wait a minute'),
      );
      expect(
        describeAuthFailure(const AuthException('Too many requests')),
        contains('Wait a minute'),
      );
    });

    test('anything else reaches the screen in Supabase own words', () {
      expect(
        describeAuthFailure(const AuthException('Email not confirmed')),
        'Email not confirmed',
      );
    });

    test('a refused read is unwrapped too — the admin check runs through one',
        () {
      expect(
        describeAuthFailure(const PostgrestException(message: 'JWT expired')),
        'JWT expired',
      );
    });

    test('a plain error still produces something to read', () {
      expect(describeAuthFailure('the socket closed'), 'the socket closed');
    });
  });

  group('AdminAuthState', () {
    test('has a state for a password accepted but no code yet', () {
      // The whole point of the enum: `is_web_admin()` is false at `aal1`, so
      // "signed in" and "may write" are not the same question, and a session
      // waiting for a code must not land on the dashboard.
      expect(AdminAuthState.values, contains(AdminAuthState.needsCode));
    });

    test('a check that could not be made is not reported as not an admin', () {
      // These two used to be one state, and it was the wrong one: a request that
      // timed out produced "Not an admin account", which is a claim about the
      // person rather than about the network. Before that it produced neither —
      // an unguarded throw inside the check left the app on "Checking your
      // sign-in…" for ever, which is what this pair exists to stop.
      expect(AdminAuthState.values, contains(AdminAuthState.failed));
      expect(AdminAuthState.failed, isNot(AdminAuthState.notAnAdmin));
    });

    test('every round trip in the check is bounded', () {
      // The check makes two of them, so the worst case is two of these before
      // the screen says something. An unbounded one is what hung the app.
      expect(adminNetworkTimeout, lessThanOrEqualTo(const Duration(seconds: 30)));
      expect(adminNetworkTimeout, greaterThan(Duration.zero));
    });
  });
}
