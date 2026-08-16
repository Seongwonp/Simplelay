import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/ble_service.dart';
import '../services/demo_service.dart';
import '../theme/app_colors.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: ref.read(savedDeviceNameProvider),
    );
    _urlController = TextEditingController(
      text: ref.read(rpiUrlProvider) ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
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
          _RpiUrlSection(controller: _urlController),
          const Divider(height: 36),
          _ApplianceSection(),
          const Divider(height: 36),
          _SavedDeviceSection(),
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
                            await ref.read(savedDeviceProvider.notifier).save(
                                  result.device.remoteId.toString(),
                                  name,
                                );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$name 연결 및 저장 완료')),
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

class _RpiUrlSection extends ConsumerWidget {
  const _RpiUrlSection({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connState = ref.watch(rpiConnectionProvider);

    final (Color stateColor, String stateLabel) = switch (connState) {
      RpiConnectionState.unconfigured => (Colors.white38, 'URL 미설정'),
      RpiConnectionState.checking     => (Colors.orange, '확인 중…'),
      RpiConnectionState.connected    => (AppColors.success, '연결됨'),
      RpiConnectionState.unreachable  => (AppColors.danger, '연결 안 됨'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('RPi 서버', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: stateColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: stateColor.withValues(alpha: 0.5)),
              ),
              child: Text(stateLabel,
                  style: TextStyle(color: stateColor, fontSize: 11)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'RPi5 FastAPI 서버 주소 (같은 Wi-Fi 필요)',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'http://192.168.0.xxx:8000',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: (_) => _save(ref),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 84,
              child: FilledButton(
                onPressed: () => _save(ref),
                child: const Text('저장'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: connState == RpiConnectionState.checking
                ? null
                : () => ref.read(rpiConnectionProvider.notifier).check(),
            icon: connState == RpiConnectionState.checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find, size: 16),
            label: const Text('연결 테스트'),
          ),
        ),
      ],
    );
  }

  Future<void> _save(WidgetRef ref) async {
    await ref.read(rpiUrlProvider.notifier).save(controller.text);
    await ref.read(rpiConnectionProvider.notifier).check();
  }
}

class _ApplianceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedApplianceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('가전 종류', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          '제어할 가전을 선택하면 버튼 맵이 연결됩니다.',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: kAppliances.map((appliance) {
            final isSelected = appliance.id == selected.id;
            return GestureDetector(
              onTap: () =>
                  ref.read(selectedApplianceProvider.notifier).select(appliance),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : Colors.white24,
                    width: isSelected ? 1.5 : 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      appliance.icon,
                      color: isSelected ? AppColors.primary : Colors.white54,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      appliance.name,
                      style: TextStyle(
                        color: isSelected ? AppColors.primary : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    if (isSelected) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.check_circle,
                          color: AppColors.primary, size: 16),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _SavedDeviceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDeviceProvider);
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final isConnected = connection == BleConnectionState.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('저장된 기기', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        if (saved == null)
          const Text('저장된 기기가 없습니다. 아래에서 기기를 연결하면 자동으로 저장됩니다.',
              style: TextStyle(color: Colors.white54))
        else
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isConnected ? AppColors.primary : Colors.white24,
                width: isConnected ? 1.5 : 0.5,
              ),
            ),
            child: ListTile(
              leading: Icon(
                Icons.bluetooth,
                color: isConnected ? AppColors.primary : Colors.white54,
              ),
              title: Text(saved.name),
              subtitle: Text(saved.id,
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isConnected)
                    const Chip(label: Text('연결됨'))
                  else
                    FilledButton(
                      onPressed: () async {
                        final results =
                            await FlutterBluePlus.scanResults.first;
                        final match = results
                            .where((r) =>
                                r.device.remoteId.toString() == saved.id)
                            .firstOrNull;
                        if (match != null && context.mounted) {
                          try {
                            await ref
                                .read(bleServiceProvider)
                                .connect(match.device);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content:
                                        Text('${saved.name} 재연결 완료')),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('연결 실패: $e')),
                              );
                            }
                          }
                        } else {
                          ref.invalidate(scanResultsProvider);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content:
                                      Text('기기를 찾지 못했습니다. 스캔 중...')),
                            );
                          }
                        }
                      },
                      child: const Text('재연결'),
                    ),
                  IconButton(
                    onPressed: () =>
                        ref.read(savedDeviceProvider.notifier).clear(),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '저장 삭제',
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
