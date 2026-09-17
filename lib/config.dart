/// Build-time configuration. Every value has a working default so a debug build
/// needs no `--dart-define`, and each can still be overridden for a throwaway
/// build against another project.
class AdminConfig {
  /// The One VTU project — the same one the student app talks to.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://kzwykhjalncwyrmcmwsc.supabase.co',
  );

  /// Publishable (anon) key. Safe to ship: every admin write is gated by the
  /// `is_web_admin()` RLS policies, not by this key.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6d3lraGphbG5jd3lybWNtd3NjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA2NjA0OTAsImV4cCI6MjA5NjIzNjQ5MH0.kLDCJR-sxM8eYj9CD9LWzIRmB_7VXwsJs7HjbhSY78k',
  );

  /// Pre-filled on the R2 settings screen. Account id and keys are deliberately
  /// absent — those are typed once on the device and kept in secure storage.
  static const String defaultBucket = String.fromEnvironment(
    'R2_BUCKET',
    defaultValue: 'vtu-resources',
  );

  /// The bucket's public r2.dev host. Four `subjects.syllabus_link` rows already
  /// point at it, so links written here match links written before.
  static const String defaultPublicBaseUrl = String.fromEnvironment(
    'R2_PUBLIC_BASE_URL',
    defaultValue: 'https://pub-195182fb36a34f84a8ac88b9369aaa3a.r2.dev',
  );
}
