import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/tts_provider.dart';
import '../services/ble_service.dart';
import '../services/demo_service.dart';
import '../theme/app_colors.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: ref.read(rpiUrlProvider) ?? '',
    );
    _apiKeyController = TextEditingController(
      text: ref.read(rpiApiKeyProvider) ?? '',
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── 기본 설정 ────────────────────────────────────────────────────
          _SectionHeader(title: '일반'),
          const SizedBox(height: 12),
          _ThemeToggleTile(),
          const SizedBox(height: 8),
          _VoiceGuideTile(),
          const SizedBox(height: 16),
          _ApplianceSection(),

          const SizedBox(height: 24),

          // ── 제안 ──────────────────────────────────────────
          _SectionHeader(title: '제안'),
          const SizedBox(height: 12),
          _SuppressionSection(),

          const SizedBox(height: 24),

          // ── 연결 ─────────────────────────────────────────────────────────
          _SectionHeader(title: '연결'),
          const SizedBox(height: 12),
          _RpiConnectionTile(),
          const SizedBox(height: 20),

          // ── ESP32 노드 ───────────────────────────────────────────────────
          _SectionHeader(title: 'ESP32 노드'),
          const SizedBox(height: 12),
          _NodeSection(),

          const SizedBox(height: 20),
          _SavedDeviceSection(),

          const SizedBox(height: 8),
          // 고급 설정 토글
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _showAdvanced
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: context.appMuted,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '고급 설정',
                    style: TextStyle(color: context.appMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 8),
            _AdvancedSection(
              controller: _urlController,
              apiKeyController: _apiKeyController,
            ),
          ],

          // ── BLE 스캔 (고급에 포함) ────────────────────────────────────────
          if (_showAdvanced) ...[
            const SizedBox(height: 20),
            _BleSection(),
          ],

          // ── 데모 (디버그 빌드만) ──────────────────────────────────────────
          if (kDebugMode) ...[
            const SizedBox(height: 24),
            _SectionHeader(title: '데모 (Debug)'),
            const SizedBox(height: 12),
            _DemoSection(),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── 섹션 헤더 ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.appMuted,
          letterSpacing: 1.2,
        ),
      );
}

// ── 음성 안내 토글 ─────────────────────────────────────────────────────────

class _VoiceGuideTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(voiceGuideProvider);
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.record_voice_over),
        title: const Text('음성 안내'),
        subtitle: Text('실행 결과를 소리로 읽어줍니다',
            style: TextStyle(color: context.appMuted, fontSize: 12)),
        value: enabled,
        onChanged: (v) => ref.read(voiceGuideProvider.notifier).set(v),
      ),
    );
  }
}

// ── 테마 토글 ─────────────────────────────────────────────────────────────

class _ThemeToggleTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLight = ref.watch(themeModeProvider) == ThemeMode.light;
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(isLight ? Icons.light_mode : Icons.dark_mode),
        title: Text(isLight ? '라이트 모드' : '다크 모드'),
        subtitle: Text(isLight ? '밝은 화면' : '어두운 화면'),
        value: isLight,
        onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
      ),
    );
  }
}

// ── RPi 연결 상태 타일 ────────────────────────────────────────────────────

class _RpiConnectionTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connState = ref.watch(rpiConnectionProvider);
    final url       = ref.watch(rpiUrlProvider);

    final (Color color, String label, IconData icon) = switch (connState) {
      RpiConnectionState.unconfigured => (context.appMuted, '미설정', Icons.wifi_off),
      RpiConnectionState.checking     => (context.appWarning, '확인 중…', Icons.sync),
      RpiConnectionState.connected    => (context.appSuccess, '연결됨', Icons.wifi),
      RpiConnectionState.unreachable  => (context.appDanger, '연결 안 됨', Icons.wifi_off),
    };

    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color, size: 22),
        title: const Text('RPi 서버'),
        subtitle: Text(
          connState == RpiConnectionState.connected
              ? (url ?? 'simplelay.local')
              : label,
          style: TextStyle(color: color, fontSize: 12),
        ),
        trailing: OutlinedButton(
          onPressed: connState == RpiConnectionState.checking
              ? null
              : () => ref.read(rpiConnectionProvider.notifier).check(),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: const Size(48, 48),
          ),
          child: connState == RpiConnectionState.checking
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('재시도', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

// ── 가전 선택 ─────────────────────────────────────────────────────────────

class _ApplianceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected   = ref.watch(selectedApplianceProvider);
    final appliances = ref.watch(allAppliancesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('제어 가전'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ...appliances.map((appliance) {
              final isSelected = appliance.id == selected.id;
              return GestureDetector(
                onTap: () => ref
                    .read(selectedApplianceProvider.notifier)
                    .select(appliance),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? context.appPrimary.withValues(alpha: 0.14)
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? context.appPrimary
                          : context.appBorderSubtle,
                      width: isSelected ? 1.5 : 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        appliance.icon,
                        color: isSelected
                            ? context.appPrimary
                            : context.appMuted,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        appliance.name,
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected
                              ? context.appPrimary
                              : context.appMuted,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.check_circle,
                            color: context.appPrimary, size: 14),
                      ],
                      if (appliance.isCustom) ...[
                        const SizedBox(width: 2),
                        // 등록 데이터(버튼맵·사진)가 즉시 유실되는 파괴적
                        // 동작 — 반드시 확인을 거친다. 히트박스도 14px
                        // 아이콘 단독이 아니라 패딩 포함으로 확대.
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _confirmRemoveAppliance(
                              context, ref, appliance),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(Icons.close,
                                color: context.appMuted, size: 14),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
            // 새 가전 추가 버튼
            GestureDetector(
              onTap: () => context.push('/appliance/new'),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: context.appBorderSubtle, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: context.appMuted, size: 18),
                    const SizedBox(width: 6),
                    Text('새 가전',
                        style: TextStyle(
                            fontSize: 13, color: context.appMuted)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmRemoveAppliance(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap appliance,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('\'${appliance.name}\' 삭제'),
        content: const Text('등록한 버튼 배치와 사진이 함께 삭제됩니다. 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            // 전경색을 명시하지 않으면 라이트 모드에서 흰 글자(3.63:1)가 된다
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.onAccent,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(customAppliancesProvider.notifier).remove(appliance.id);
      // 서버(키오스크 목록)에서도 제거 — 실패해도 폰 삭제는 유지(best-effort)
      await ref.read(rpiApiServiceProvider)?.deleteAppliance(appliance.id);
    }
  }
}

// ── 저장된 BLE 기기 ───────────────────────────────────────────────────────

class _SavedDeviceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved      = ref.watch(savedDeviceProvider);
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final isConnected = connection == BleConnectionState.connected;

    if (saved == null) {
      return _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.bluetooth_disabled,
              color: context.appMuted, size: 22),
          title: const Text('BLE 기기'),
          subtitle: Text('저장된 기기 없음 — 고급 설정에서 스캔',
              style: TextStyle(color: context.appMuted, fontSize: 12)),
        ),
      );
    }

    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: isConnected ? context.appPrimary : context.appMuted,
          size: 22,
        ),
        title: Text(saved.name),
        subtitle: Text(
          isConnected ? '연결됨' : '연결 안 됨',
          style: TextStyle(
            color: isConnected ? context.appSuccess : context.appMuted,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isConnected)
              OutlinedButton(
                onPressed: () async {
                  // 저장된 기기를 실제로 스캔해서 찾는다 — 이전 구현은 스캔을
                  // 시작하지도 않고 결과 스트림의 첫 이벤트를 기다려서, 다른
                  // 스캔이 돌고 있지 않으면 영원히 완료되지 않았다.
                  final ble = ref.read(bleServiceProvider);
                  final messenger = ScaffoldMessenger.of(context);
                  ScanResult? match;
                  try {
                    await for (final results in ble
                        .scan(timeout: const Duration(seconds: 8))
                        .timeout(const Duration(seconds: 9))) {
                      match = results
                          .where((r) =>
                              r.device.remoteId.toString() == saved.id)
                          .firstOrNull;
                      if (match != null) break;
                    }
                  } catch (_) {
                    // 타임아웃 포함 — match == null로 아래에서 안내
                  }
                  await ble.stopScan();
                  if (match == null) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('저장된 기기를 찾지 못했어요. 기기 전원을 확인해주세요.'),
                    ));
                    return;
                  }
                  try {
                    await ble.connect(match.device);
                  } catch (_) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('연결에 실패했어요. 다시 시도해주세요.'),
                    ));
                  }
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  minimumSize: const Size(48, 48),
                ),
                child:
                    const Text('재연결', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              onPressed: () =>
                  ref.read(savedDeviceProvider.notifier).clear(),
              icon: const Icon(Icons.delete_outline, size: 16),
              color: context.appMuted,
              tooltip: '삭제',
              padding: const EdgeInsets.all(4),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 고급 설정 (URL 오버라이드) ────────────────────────────────────────────

class _AdvancedSection extends ConsumerWidget {
  const _AdvancedSection({
    required this.controller,
    required this.apiKeyController,
  });
  final TextEditingController controller;
  final TextEditingController apiKeyController;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RPi 서버 주소',
            style: TextStyle(color: context.appMuted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '기본값: http://simplelay.local:8000\n'
            '같은 Wi-Fi에서 mDNS로 자동 연결됩니다.',
            style: TextStyle(color: context.appMuted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'http://simplelay.local:8000',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: (_) => _save(ref),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _save(ref),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('저장', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'API 키 (선택)',
            style: TextStyle(color: context.appMuted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '서버에 SIMPLELAY_API_KEY가 설정된 경우에만 입력하세요.\n'
            '시연장 등 공유 Wi-Fi에서 외부 접근을 막는 용도입니다.',
            style: TextStyle(color: context.appMuted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: apiKeyController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '미설정 시 비워두세요',
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
            autocorrect: false,
            obscureText: true,
            onSubmitted: (_) => _save(ref),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () async {
              await ref.read(rpiUrlProvider.notifier).resetToDefault();
              controller.text = 'http://simplelay.local:8000';
              await ref.read(rpiConnectionProvider.notifier).check();
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
            ),
            child: Text('기본값으로 초기화',
                style:
                    TextStyle(color: context.appMuted, fontSize: 12)),
          ),
        ],
      );

  Future<void> _save(WidgetRef ref) async {
    await ref.read(rpiApiKeyProvider.notifier).save(apiKeyController.text);
    await ref.read(rpiUrlProvider.notifier).save(controller.text);
    await ref.read(rpiConnectionProvider.notifier).check();
  }
}

// ── BLE 스캔 섹션 ─────────────────────────────────────────────────────────

class _BleSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(scanResultsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('주변 BLE 기기',
                style: TextStyle(color: context.appMuted, fontSize: 13)),
            const Spacer(),
            IconButton(
              onPressed: () => ref.invalidate(scanResultsProvider),
              icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
              tooltip: '다시 스캔',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 48, minHeight: 48),
            ),
          ],
        ),
        const SizedBox(height: 8),
        results.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('스캔 실패: $e',
              style: TextStyle(color: context.appMuted, fontSize: 12)),
          data: (items) {
            final unique = <DeviceIdentifier, ScanResult>{
              for (final item in items) item.device.remoteId: item,
            }.values;
            if (unique.isEmpty) {
              return Text('검색된 기기가 없습니다.',
                  style:
                      TextStyle(color: context.appMuted, fontSize: 12));
            }
            return Column(
              children: unique.map((result) {
                final name = result.device.platformName.isEmpty
                    ? '이름 없는 기기'
                    : result.device.platformName;
                return _SettingCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bluetooth, size: 20),
                    title: Text(name, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      '${result.rssi} dBm',
                      style: TextStyle(
                          color: context.appMuted, fontSize: 11),
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
                              SnackBar(content: Text('$name 연결 완료')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('연결 실패: $e')),
                            );
                          }
                        }
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('연결',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

// ── 데모 섹션 ─────────────────────────────────────────────────────────────

class _DemoSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () {
              DemoService(ref.read(bleServiceProvider)).injectSuggestion();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('데모 제안 주입 완료')),
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
        ],
      );
}

// ── ESP32 노드 등록 ───────────────────────────────────────────────────────

class _NodeSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(allAppliancesProvider);
    final nodesAsync = ref.watch(nodeRegistryProvider);

    return nodesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, __) => _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.error_outline, color: context.appMuted, size: 20),
          title: Text('노드 목록 불러오기 실패',
              style: TextStyle(color: context.appMuted, fontSize: 13)),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
            onPressed: () => ref.invalidate(nodeRegistryProvider),
          ),
        ),
      ),
      data: (nodes) => Column(
        children: appliances.map((appliance) {
          final url = nodes[appliance.id];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SettingCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(appliance.icon,
                    color: url != null
                        ? context.appSuccess
                        : context.appMuted,
                    size: 20),
                title: Text(appliance.name),
                subtitle: Text(
                  url ?? '미등록',
                  style: TextStyle(
                    color: url != null
                        ? context.appSuccess
                        : context.appMuted,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: Icon(
                    url != null ? Icons.edit_outlined : Icons.add_circle_outline,
                    color: context.appMuted,
                    size: 18,
                  ),
                  onPressed: () => _showNodeSheet(context, ref, appliance, url),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showNodeSheet(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap appliance,
    String? currentUrl,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NodeEditSheet(
        appliance: appliance,
        currentUrl: currentUrl,
        onSave: (url) async {
          final service = ref.read(rpiApiServiceProvider);
          if (service == null) return false;
          final ok = await service.registerNode(appliance.id, url);
          if (ok) ref.invalidate(nodeRegistryProvider);
          return ok;
        },
        onUnregister: () async {
          final service = ref.read(rpiApiServiceProvider);
          if (service == null) return false;
          final ok = await service.unregisterNode(appliance.id);
          if (ok) ref.invalidate(nodeRegistryProvider);
          return ok;
        },
      ),
    );
  }
}

class _NodeEditSheet extends StatefulWidget {
  const _NodeEditSheet({
    required this.appliance,
    required this.currentUrl,
    required this.onSave,
    required this.onUnregister,
  });

  final ApplianceMap appliance;
  final String? currentUrl;
  final Future<bool> Function(String url) onSave;
  final Future<bool> Function() onUnregister;

  @override
  State<_NodeEditSheet> createState() => _NodeEditSheetState();
}

class _NodeEditSheetState extends State<_NodeEditSheet> {
  late final TextEditingController _ctrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentUrl ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _normalize(String input) {
    final s = input.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.contains(':')) return 'http://$s';
    return 'http://$s:8080';
  }

  Future<void> _save() async {
    final url = _normalize(_ctrl.text);
    if (url.isEmpty) return;
    setState(() { _saving = true; _error = null; });
    final ok = await widget.onSave(url);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() { _saving = false; _error = '저장 실패 — RPi 서버에 연결되어 있는지 확인하세요'; });
    }
  }

  Future<void> _unregister() async {
    setState(() { _saving = true; _error = null; });
    final ok = await widget.onUnregister();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() { _saving = false; _error = '해제 실패'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegistered = widget.currentUrl != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              // 핸들
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.appOutline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // 헤더
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(widget.appliance.icon,
                        color: context.appPrimary, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      '${widget.appliance.name} 노드 등록',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isRegistered) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.appSuccess.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: context.appSuccess.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          '등록됨',
                          style: TextStyle(
                              fontSize: 11, color: context.appSuccess),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'ESP32 IP 입력 — 포트는 자동으로 :8080이 붙습니다',
                  style: TextStyle(
                      fontSize: 12, color: context.appMuted),
                ),
              ),

              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 16),

              // 입력 필드
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: '192.168.x.x  또는  http://...:8080',
                    hintStyle: TextStyle(
                        fontSize: 13, color: context.appMuted),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onSubmitted: (_) => _save(),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _error!,
                    style: TextStyle(
                        fontSize: 12, color: context.appDanger),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // 버튼 행
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    if (isRegistered)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : _unregister,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.appDanger,
                            side: BorderSide(
                                color: context.appDanger.withValues(alpha: 0.5)),
                          ),
                          child: const Text('해제'),
                        ),
                      ),
                    if (isRegistered) const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('저장'),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 공통 카드 컨테이너 ────────────────────────────────────────────────────

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.child});
  final Widget child;

  @override
  // 배경색은 Material에 둔다 — ListTile은 잉크·배경을 가장 가까운 Material에
  // 그리는데, 색 있는 DecoratedBox가 그 사이에 끼면 Flutter 3.4x부터
  // assertion으로 막힌다. 테두리만 안쪽 (색 없는) 데코레이션으로 유지.
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.appBorderSubtle, width: 0.5),
          ),
          child: child,
        ),
      );
}


/// 다시 추천 안 하는 루틴 목록 -- 개별 해제(다시 받기) 가능.
class _SuppressionSection extends ConsumerStatefulWidget {
  const _SuppressionSection();

  @override
  ConsumerState<_SuppressionSection> createState() =>
      _SuppressionSectionState();
}

class _SuppressionSectionState extends ConsumerState<_SuppressionSection> {
  Future<List<String>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final api = ref.read(rpiApiServiceProvider);
    setState(() {
      _future = api?.suppressions() ?? Future<List<String>>.value(const []);
    });
  }

  Future<void> _unmute(String purpose) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api != null) {
      try {
        await api.unmuteSuppression(purpose);
      } catch (_) {}
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <String>[];
        if (items.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              '다시 추천 안 하는 항목이 없어요.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }
        return Column(
          children: [
            for (final purpose in items)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(purpose),
                trailing: TextButton(
                  onPressed: () => _unmute(purpose),
                  child: const Text('다시 받기'),
                ),
              ),
          ],
        );
      },
    );
  }
}

