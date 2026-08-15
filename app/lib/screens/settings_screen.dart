import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_provider.dart';
import '../services/demo_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: ref.read(savedDeviceNameProvider),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(scanResultsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('기기 이름', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'SimpleLay',
            ),
            onSubmitted: (value) =>
                ref.read(savedDeviceNameProvider.notifier).save(value),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                await ref
                    .read(savedDeviceNameProvider.notifier)
                    .save(_nameController.text);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('기기 이름을 저장했습니다.')),
                  );
                }
              },
              child: const Text('저장'),
            ),
          ),
          const Divider(height: 36),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('주변 BLE 기기', style: Theme.of(context).textTheme.titleMedium),
              IconButton(
                onPressed: () => ref.invalidate(scanResultsProvider),
                icon: const Icon(Icons.refresh),
                tooltip: '다시 스캔',
              ),
            ],
          ),
          if (kDebugMode) ...[
            const Divider(height: 36),
            Text('데모 (하드웨어 없이 테스트)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                DemoService(ref.read(bleServiceProvider)).injectSuggestion();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('데모 제안을 주입했습니다. 홈 화면을 확인하세요.')),
                );
              },
              icon: const Icon(Icons.science_outlined),
              label: const Text('제안 시뮬레이션'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                ref.read(bleServiceProvider).simulateDisconnected();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('연결 해제 시뮬레이션')),
                );
              },
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('연결 해제'),
            ),
            const Divider(height: 36),
          ],
          results.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('스캔 실패: $error'),
            ),
            data: (items) {
              final unique = <DeviceIdentifier, ScanResult>{
                for (final item in items) item.device.remoteId: item,
              }.values;
              if (unique.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('검색된 기기가 없습니다.')),
                );
              }
              return Column(
                children: unique.map((result) {
                  final name = result.device.platformName.isEmpty
                      ? '이름 없는 기기'
                      : result.device.platformName;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(name),
                      subtitle: Text(
                        '${result.device.remoteId} · ${result.rssi} dBm',
                      ),
                      trailing: FilledButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(bleServiceProvider)
                                .connect(result.device);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$name 연결 완료')),
                              );
                            }
                          } catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('연결 실패: $error')),
                              );
                            }
                          }
                        },
                        child: const Text('연결'),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
