import 'package:masi/core/config/supabase_config.dart';
import 'package:masi/core/config/supabase_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'supabaseClientProvider is readable once overridden with a client '
    '(no real network call is made by construction alone)',
    () {
      final fakeClient = SupabaseClient(supabaseUrl, supabaseAnonKey);
      final container = ProviderContainer(
        overrides: [
          supabaseClientProvider.overrideWithValue(fakeClient),
        ],
      );
      addTearDown(container.dispose);

      final readClient = container.read(supabaseClientProvider);

      expect(readClient, isA<SupabaseClient>());
      expect(readClient, same(fakeClient));
    },
  );
}
