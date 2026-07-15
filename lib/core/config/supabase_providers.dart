import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Exposes the process-wide [SupabaseClient] created by
/// `Supabase.initialize` in `main()`.
///
/// Assumes `Supabase.initialize` has already run before this provider is
/// first read (it is, in `main()`, before `runApp`). Later auth/backup
/// providers should `ref.watch` this rather than reaching for
/// `Supabase.instance.client` directly, so tests can override it.
final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);
