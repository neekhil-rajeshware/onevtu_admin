import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Where the app is in the sign-in flow.
enum AdminAuthState {
  /// Restoring a stored session.
  checking,

  /// Nobody is signed in.
  signedOut,

  /// The password was accepted, but this session is still `aal1` and the account
  /// has an authenticator app — so a six-digit code is outstanding.
  needsCode,

  /// Signed in, but no `web_admins` row — so RLS would refuse every write.
  notAnAdmin,

  /// The check itself could not be made: no answer from the server, or a stored
  /// session that cannot be read. **Not** the same as [notAnAdmin] — this says
  /// nothing about the account, and retrying is the first thing to try.
  failed,

  /// Signed in and an admin.
  ready,
}

/// How long any one round trip may take before the app stops waiting for it.
///
/// Two of these bound the whole check. Without them the app had no way out of
/// [AdminAuthState.checking]: a request on a network that accepts the connection
/// and then stalls never completes and never throws, so the screen stayed on
/// "Checking your sign-in…" indefinitely — with no retry and nothing to read.
const Duration adminNetworkTimeout = Duration(seconds: 10);

/// Where a password-reset link is sent to be opened — the website's recovery
/// page, whose origin is already on Supabase's redirect allow-list because its
/// own sign-in page uses the same URL. Must stay in step with
/// `admin/login-form.tsx` in the website repo.
const passwordRecoveryUrl =
    'https://onevtu.in/auth/confirm?next=%2Fadmin%2Faccount%3Frecovery%3D1';

/// Turns Supabase's developer-facing wording into the sentences an admin can act
/// on. A top-level function so it can be tested without a client.
String describeAuthFailure(Object error) {
  final message = switch (error) {
    AuthException(:final message) => message,
    PostgrestException(:final message) => message,
    _ => error.toString(),
  };
  final lower = message.toLowerCase();
  if (lower.contains('invalid login credentials')) {
    return 'That email and password do not match.';
  }
  if (lower.contains('invalid totp') || lower.contains('invalid code')) {
    return 'That code was not right. Codes change every 30 seconds — try the '
        'one showing now.';
  }
  if (lower.contains('rate limit') || lower.contains('too many')) {
    return 'Too many tries. Wait a minute and enter a fresh code.';
  }
  return message;
}

/// Owns the Supabase session and answers the only question the UI cares about:
/// may this person write?
///
/// Being signed in is deliberately not enough, and neither is the password on its
/// own. `is_web_admin()` requires a row in `web_admins` **and** a session at
/// `aal2` whenever the account has a verified authenticator — so a password-only
/// session reads fine and has every write refused. This class checks both the
/// same way, so the app can say what is missing instead of failing on each save.
class AdminSession extends ChangeNotifier {
  AdminSession(this._client) {
    _subscription = _client.auth.onAuthStateChange.listen((event) {
      // Ignore token refreshes: they do not change who is signed in, and
      // re-checking on every refresh would flicker the whole UI.
      if (event.event == AuthChangeEvent.tokenRefreshed) return;
      _resolve();
    });
    _resolve();
  }

  final SupabaseClient _client;
  late final StreamSubscription<AuthState> _subscription;

  AdminAuthState _state = AdminAuthState.checking;
  AdminAuthState get state => _state;

  String? _error;
  String? get error => _error;

  bool _busy = false;
  bool get busy => _busy;

  List<Factor> _factors = const [];

  /// The authenticator apps that finished setup. More than one means the admin
  /// has to say which app is on the phone in their hand — the codes differ.
  List<Factor> get factors => _factors;

  String? get email => _client.auth.currentUser?.email;

  Future<void>? _resolving;

  /// Signing in fires an auth event *and* returns, so two resolves can start at
  /// once — and each one refreshes the session. The second waits for the first
  /// rather than racing it through a token refresh.
  Future<void> _resolve() {
    final running = _resolving;
    if (running != null) return running;
    final future = _resolveOnce();
    _resolving = future;
    return future.whenComplete(() => _resolving = null);
  }

  Future<void> _resolveOnce() async {
    // The **whole** body is guarded, not just the request. Beyond the two round
    // trips this reads the token already on the device — and a stored session
    // that cannot be decoded throws from there, outside every request and
    // previously outside every catch. That left the app on "Checking your
    // sign-in…" with nothing to read and no way forward.
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        _factors = const [];
        _set(AdminAuthState.signedOut);
        return;
      }

      // The second factor is settled before the admin row, because at `aal1`
      // `is_web_admin()` is false whatever `web_admins` says — calling that "not an
      // admin" would send someone to a dead end over a missing code.
      _factors = await _verifiedFactors();
      if (_factors.isNotEmpty && !_atFullLevel) {
        _set(AdminAuthState.needsCode);
        return;
      }

      try {
        // `web_admins` lets an admin read only their own row, so this returns
        // either that row or nothing — never someone else's.
        final row = await _client
            .from('web_admins')
            .select('user_id')
            .eq('user_id', user.id)
            .maybeSingle()
            .timeout(adminNetworkTimeout);
        _set(row == null ? AdminAuthState.notAnAdmin : AdminAuthState.ready);
      } on PostgrestException catch (error) {
        // The database answered and refused. That is a fact about the account,
        // which is exactly what `notAnAdmin` means.
        _error = describeAuthFailure(error);
        _set(AdminAuthState.notAnAdmin);
      }
    } on TimeoutException {
      _error = 'The server did not answer in time. Check your connection and '
          'try again.';
      _set(AdminAuthState.failed);
    } catch (error) {
      // No route to the server, a socket that closed, a token that will not
      // decode — none of these say anything about who this account is, so none
      // of them may be reported as "not an admin".
      _error = describeAuthFailure(error);
      _set(AdminAuthState.failed);
    }
  }

  /// Runs the check again, for the retry button on [AdminAuthState.failed].
  ///
  /// Safe to call while one is still in flight: [_resolve] hands back the
  /// running one rather than starting a second session refresh.
  Future<void> retry() => _resolve();

  /// Only the apps that finished setup count: an abandoned setup leaves an
  /// unverified factor behind, and `is_web_admin()` ignores those too.
  Future<List<Factor>> _verifiedFactors() async {
    try {
      // Refreshes the session first, which is how an authenticator added on the
      // website since this session was stored gets noticed.
      final response =
          await _client.auth.mfa.listFactors().timeout(adminNetworkTimeout);
      return response.totp;
    } catch (_) {
      // Offline, a refresh that failed, or a request that never answered. The
      // token already on the device lists them, which is enough to know a code
      // is needed.
      return _factorsFromToken();
    }
  }

  /// The factors the stored token itself names, read without a round trip.
  List<Factor> _factorsFromToken() =>
      (_client.auth.currentUser?.factors ?? [])
          .where((factor) =>
              factor.factorType == FactorType.totp &&
              factor.status == FactorStatus.verified)
          .toList();

  bool get _atFullLevel =>
      _client.auth.mfa.getAuthenticatorAssuranceLevel().currentLevel ==
      AuthenticatorAssuranceLevels.aal2;

  /// Returns whether the **password** was accepted. Being in is a separate
  /// question: [state] answers that, and may ask for a code next.
  Future<bool> signIn(String email, String password) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      await _resolve();
      return true;
    } catch (error) {
      _error = describeAuthFailure(error);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// The second step: the six digits an authenticator app is showing. Supabase
  /// stamps `aal2` into the replacement token, which is what `is_web_admin()` —
  /// and so every write policy — has been waiting for.
  Future<bool> submitCode({
    required String factorId,
    required String code,
  }) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _client.auth.mfa.challengeAndVerify(
        factorId: factorId,
        code: code.trim(),
      );
      await _resolve();
      return _state == AdminAuthState.ready;
    } catch (error) {
      _error = describeAuthFailure(error);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// The admin account was created through Google sign-in in the student app,
  /// so it may have no password yet — this is how it gets one.
  ///
  /// The link has to land somewhere that can actually set a password, and this
  /// app is not it: there is no deep link, and Supabase's default lands on the
  /// site root, which ignores the recovery token. So it points at the website's
  /// own recovery page, the same URL its "Forgot your password?" uses.
  Future<bool> sendPasswordReset(String email) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _client.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: passwordRecoveryUrl,
      );
      return true;
    } catch (error) {
      _error = describeAuthFailure(error);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Clears the stored session — and clears it **locally** even when the server
  /// cannot be reached, which is the only way out of a session this device can no
  /// longer read.
  Future<void> signOut() async {
    try {
      await _client.auth.signOut().timeout(adminNetworkTimeout);
    } catch (_) {
      // Offline, or the token was already refused. The local session still has
      // to go, or the next launch lands right back here.
      try {
        await _client.auth.signOut(scope: SignOutScope.local);
      } catch (_) {
        // Nothing left to try: the state below is what the UI reads either way.
      }
    } finally {
      _factors = const [];
      _error = null;
      _set(AdminAuthState.signedOut);
    }
  }

  void _set(AdminAuthState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
