import 'package:flutter/foundation.dart';

import '../schema/field_spec.dart';
import 'admin_repository.dart';

/// Why a dropdown has nothing in it. Thrown rather than swallowed so the sheet
/// can say "could not read branches" instead of showing an empty list, which
/// looks exactly like a reference table that is genuinely empty.
class LookupException implements Exception {
  const LookupException(this.table, this.cause);

  final String table;
  final Object cause;

  @override
  String toString() => 'Could not read $table. $cause';
}

/// Caches dropdown options for the life of the session.
///
/// Without this every field with a lookup would hit the network each time a form
/// opened, and `subjects` alone has five.
class LookupCache {
  LookupCache(this._repository);

  final AdminRepository _repository;
  final Map<String, Future<List<LookupOption>>> _inFlight = {};
  final Map<String, List<LookupOption>> _resolved = {};

  List<LookupOption>? peek(Lookup lookup) => _resolved[lookup.cacheKey];

  Future<List<LookupOption>> options(Lookup lookup) {
    final key = lookup.cacheKey;
    final resolved = _resolved[key];
    if (resolved != null) return Future.value(resolved);

    return _inFlight.putIfAbsent(key, () async {
      try {
        final options = await _repository.lookup(lookup);
        _resolved[key] = options;
        return options;
      } catch (error) {
        // Deliberately not cached. Caching an empty list here — as this used to —
        // meant one dropped request left every dropdown on that table empty for
        // the rest of the session, with nothing on screen saying why.
        debugPrint('Lookup $key failed: $error');
        throw LookupException(lookup.table, error);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// Called after a save so a newly added scheme or branch shows up in the
  /// dropdowns that read it.
  void invalidate() {
    _resolved.clear();
    _inFlight.clear();
  }
}
