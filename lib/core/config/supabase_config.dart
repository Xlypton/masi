/// Supabase project configuration.
///
/// SECURITY: the values below are the publishable **anon** key and the
/// project URL. Both are safe to embed in the compiled app and to commit to
/// this repository — every table the client can reach is protected by
/// Postgres Row Level Security (RLS) scoped to `auth.uid()`, and Storage
/// objects live under an equivalent per-user path convention.
///
/// The Supabase privileged/elevated key (the one that bypasses RLS
/// entirely — NOT the publishable one above) is a completely different
/// credential. It must NEVER be added to this file, hard-coded anywhere
/// else in the app, checked into the repo, or shipped in a build. It only
/// ever belongs in trusted server-side contexts (e.g. Supabase Edge
/// Functions, a backend you control) — never in client code.
///
/// Both values may be overridden at build/run time without touching this
/// file via `--dart-define`, e.g.:
///
/// ```
/// flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
/// ```
library;

/// The Supabase project URL.
const String supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://mnaipcqbkqzffgvxpato.supabase.co',
);

/// The Supabase publishable/anon key. Safe to embed — RLS-protected.
///
/// Do NOT put the privileged/elevated key here or anywhere in this app.
const String supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_CjAxoGe0OSS0RrIK3nT6Ng_p0-uSPKC',
);
