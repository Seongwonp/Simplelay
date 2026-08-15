import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/suggestion_provider.dart';

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('SuggestionNotifier', () {
    test('initially empty', () {
      final c = makeContainer();
      expect(c.read(suggestionProvider), isEmpty);
    });

    test('adds suggestion when BLE suggestion message arrives', () async {
      final c = makeContainer();
      c.read(suggestionProvider); // initialise notifier

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'test-001',
        'label': '우유 데우기',
        'steps': ['BT-08', 'BT-03', 'BT-05'],
      });

      await Future<void>.delayed(Duration.zero);
      final suggestions = c.read(suggestionProvider);
      expect(suggestions.length, 1);
      expect(suggestions.first.sequenceId, 'test-001');
      expect(suggestions.first.label, '우유 데우기');
    });

    test('replaces existing suggestion with same sequenceId', () async {
      final c = makeContainer();
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'dup-001',
        'label': '첫 번째',
        'steps': ['BT-01'],
      });
      await Future<void>.delayed(Duration.zero);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'dup-001',
        'label': '업데이트됨',
        'steps': ['BT-02'],
      });
      await Future<void>.delayed(Duration.zero);

      final suggestions = c.read(suggestionProvider);
      expect(suggestions.length, 1);
      expect(suggestions.first.label, '업데이트됨');
    });

    test('ignores non-suggestion messages', () async {
      final c = makeContainer();
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({'type': 'sensor', 'current_ma': 300.0});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(suggestionProvider), isEmpty);
    });

    test('respond removes suggestion from state', () async {
      final c = makeContainer();
      c.read(bleServiceProvider).simulateConnected(); // demo mode so send is no-op
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'remove-me',
        'label': '삭제될 제안',
        'steps': ['BT-05'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.read(suggestionProvider).length, 1);

      await c.read(suggestionProvider.notifier).respond(
            c.read(suggestionProvider).first,
            false,
          );
      expect(c.read(suggestionProvider), isEmpty);
    });
  });
}
