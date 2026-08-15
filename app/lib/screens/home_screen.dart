import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/ble_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final suggestions = ref.watch(suggestionProvider);
    final connected = connection == BleConnectionState.connected;
    return Scaffold(
      appBar: AppBar(title: const Text('SimpleLay')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: connected ? () => context.go('/voice') : null,
        icon: const Icon(Icons.mic),
        label: const Text('말하기'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(20),
              leading: CircleAvatar(
                backgroundColor: connected ? Colors.green : Colors.white12,
                child: Icon(
                  connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                ),
              ),
              title: Text(connected ? '기기 연결됨' : '기기 연결 필요'),
              subtitle: Text(
                connected ? '명령을 보낼 준비가 되었습니다.' : '설정에서 SimpleLay 기기를 연결하세요.',
              ),
              trailing: !connected
                  ? TextButton(
                      onPressed: () => context.go('/settings'),
                      child: const Text('연결'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 28),
          Text('대기 중인 제안', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (suggestions.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: Text('새로운 제안이 없습니다.')),
              ),
            )
          else
            ...suggestions.map(
              (suggestion) => Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(suggestion.label),
                  subtitle: Text('${suggestion.steps.length}단계 동작'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      context.push('/suggestion/${suggestion.sequenceId}'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
