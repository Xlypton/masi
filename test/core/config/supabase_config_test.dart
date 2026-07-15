import 'package:climbtopo/core/config/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('supabase_config', () {
    test('supabaseUrl is non-empty and uses https', () {
      expect(supabaseUrl, isNotEmpty);
      expect(supabaseUrl.startsWith('https://'), isTrue);
    });

    test('supabaseAnonKey is non-empty', () {
      expect(supabaseAnonKey, isNotEmpty);
    });

    test('supabaseAnonKey is not a secret/service-role key', () {
      final lower = supabaseAnonKey.toLowerCase();
      expect(lower.contains('secret'), isFalse);
      expect(lower.contains('service_role'), isFalse);
    });
  });
}
