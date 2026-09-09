import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../models/execution_status.dart';
import '../providers/appliance_sync_provider.dart';
import '../providers/wellness_pause_provider.dart';
import '../providers/demo_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/tts_provider.dart';
import '../services/ble_service.dart';
import '../services/demo_service.dart';
import '../theme/app_colors.dart';

import '../widgets/dnd_bottom_sheet.dart';
import '../widgets/sync_status_line.dart';

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

          // ── 알림 ──────────────────────────────────────────
          _SectionHeader(title: '알림'),
          const SizedBox(height: 12),
          _DndTile(),
          const SizedBox(height: 12),
          _WellnessPauseTile(),

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
                    _showAdvanced ? Icons.expand_less : Icons.expand_more,
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

          // ── 데모 ──────────────────────────────────────────────────────────
          // 디버그 빌드가 아니라 '고급'에 둔다. 결선 리허설은 릴리즈 APK로
          // 하는데, 디버그에만 있으면 정작 필요한 곳에서 못 켠다. 대신
          // 켜져 있는 동안에는 실행 화면이 그 사실을 계속 표시한다.
          if (_showAdvanced) ...[
            const SizedBox(height: 24),
            _SectionHeader(title: '데모'),
            const SizedBox(height: 12),
            _DemoModeTile(),
            const SizedBox(height: 8),
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
    final url = ref.watch(rpiUrlProvider);

    final (Color color, String label, IconData icon) = switch (connState) {
      RpiConnectionState.unconfigured => (
          context.appMuted,
          '미설정',
          Icons.wifi_off
        ),
      RpiConnectionState.checking => (context.appWarning, '확인 중…', Icons.sync),
      RpiConnectionState.connected => (context.appSuccess, '연결됨', Icons.wifi),
      RpiConnectionState.unreachable => (
          context.appDanger,
          '연결 안 됨',
          Icons.wifi_off
        ),
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
    final selected = ref.watch(selectedApplianceProvider);
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
              // 선택 상태를 시맨틱으로 노출한다 -- 체크 아이콘은 눈으로만
              // 보이는 신호라, 스크린리더 사용자는 가전 이름은 읽어도
              // 무엇이 선택됐는지 알 수 없었다.
              return Semantics(
                button: true,
                selected: isSelected,
                child: GestureDetector(
                  onTap: () => ref
                      .read(selectedApplianceProvider.notifier)
                      .select(appliance),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    // 터치 목표 하한. 고령 사용자 대상이라 WCAG 2.2 AA의
                    // 최소치(24)보다 높은 48을 제품 기준으로 잡는다.
                    constraints: const BoxConstraints(minHeight: 48),
                    alignment: Alignment.center,
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
                ),
              );
            }),
            // 새 가전 추가 버튼
            GestureDetector(
              onTap: () => context.push('/appliance/new'),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: context.appBorderSubtle, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: context.appMuted, size: 18),
                    const SizedBox(width: 6),
                    Text('새 가전',
                        style:
                            TextStyle(fontSize: 13, color: context.appMuted)),
                  ],
                ),
              ),
            ),
          ],
        ),
        // 아직 키오스크에 못 보낸 변경이 있으면 **여기서 먼저 말한다.**
        // 평상시에는 아무것도 띄우지 않는다 -- 늘 떠 있는 상태 표시는
        // 읽히지 않고, 정작 문제가 생겼을 때도 눈에 안 들어온다.
        SyncStatusLine(onRetry: () => _resyncCustomAppliances(context, ref)),
        if (ref.watch(hasPendingSyncProvider)) ...[
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _resyncCustomAppliances(context, ref),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: Icon(Icons.sync, size: 18, color: context.appMuted),
            label: Text(
              '키오스크와 다시 동기화',
              style: TextStyle(fontSize: 13, color: context.appMuted),
            ),
          ),
        ],
      ],
    );
  }

  /// 양방향 동기화. **다른 폰이 등록한 가전을 지우지 않는다** — 서버에만
  /// 있다는 것은 "지워도 된다"가 아니라 "이 폰이 아직 못 받았다"는 뜻이다.
  Future<void> _resyncCustomAppliances(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(rpiApiServiceProvider) == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('서버 주소를 먼저 설정해 주세요.')),
      );
      return;
    }
    // 이 버튼은 복구 수단이다 — 대기열에 없던 가전(서버가 꺼져 있던 시절에
    // 등록한 것)까지 다시 올린다.
    final result = await ref.read(applianceSyncProvider.notifier).resendAll();
    messenger.showSnackBar(SnackBar(content: Text(_syncMessage(result))));
  }

  /// 사용자 문구에는 내부 용어(upsert·tombstone·revision·409)를 쓰지 않는다.
  static String _syncMessage(ApplianceSyncResult r) {
    if (r.conflicts > 0) {
      // 자동으로 덮어쓰지 않았다는 것을 분명히 말한다.
      return '다른 기기에서 변경되어 서버 내용을 가져왔어요.';
    }
    if (r.allDone) {
      final parts = [
        if (r.sent > 0) '보냄 ${r.sent}건',
        if (r.adopted > 0) '새로 받음 ${r.adopted}개',
      ];
      return parts.isEmpty
          ? '이미 키오스크와 같은 상태예요.'
          : '동기화했어요 — ${parts.join(' · ')}.';
    }
    if (r.failed > 0) {
      return '변경 ${r.failed}건을 보내지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.';
    }
    return '키오스크 목록을 불러오지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.';
  }

  Future<void> _confirmRemoveAppliance(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap appliance,
  ) async {
    // async gap 전에 캡처 — 다이얼로그가 닫힌 뒤의 context 사용을 피한다
    final messenger = ScaffoldMessenger.of(context);
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
      // 폰 삭제는 무조건 성립하고(사용자가 지시한 일이다), 서버 전송이
      // 실패하면 그 사실이 삭제 대기열에 남아 다음 동기화가 다시 보낸다.
      // 예전에는 실패를 스낵바로만 알리고 잊어서, 복구가 "서버에만 있는
      // 건 다 지운다"는 위험한 방식에 얹혀 있었다 (R3).
      final result = await ref
          .read(applianceSyncProvider.notifier)
          .deleteAppliance(appliance.id);
      if (result.failed > 0) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('폰에서는 삭제했어요. 키오스크 반영은 다음 동기화 때 '
                '다시 시도할게요.'),
          ),
        );
      }
    }
  }
}

// ── 저장된 BLE 기기 ───────────────────────────────────────────────────────

class _SavedDeviceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDeviceProvider);
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final isConnected = connection == BleConnectionState.connected;

    if (saved == null) {
      return _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.bluetooth_disabled, color: context.appMuted, size: 22),
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
                          .where(
                              (r) => r.device.remoteId.toString() == saved.id)
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('재연결', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              onPressed: () => ref.read(savedDeviceProvider.notifier).clear(),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                style: TextStyle(color: context.appMuted, fontSize: 12)),
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
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
                  style: TextStyle(color: context.appMuted, fontSize: 12));
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
                      style: TextStyle(color: context.appMuted, fontSize: 11),
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
                      child: const Text('연결', style: TextStyle(fontSize: 12)),
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

/// 안부 확인을 며칠 쉰다 — 집을 비운 것을 **아는** 날들.
///
/// 여행·입원처럼 조용한 것이 정상인 날에도 안부 신호는 그대로 울린다.
/// 보호자는 이미 알고 있는 일로 알림을 받고, 며칠 이어지면 정작 진짜 신호가
/// 왔을 때 무시하게 된다 — 안부 기능이 스스로를 무디게 만든다.
///
/// 방해 금지(제안 쪽)와 다른 자리에 둔 이유: 하나로 묶으면 방해 금지 30분이
/// 안부 확인까지 꺼버리거나, 여행 일주일이 제안까지 막는다.
/// 방해 금지 — 제안을 잠시 쉰다.
///
/// 홈 앱바의 아이콘에서 옮겨 왔다. 뜻을 추측해야 하는 그림이 여럿 붙어
/// 있으면 디지털에 익숙하지 않은 사용자에게는 그 줄 전체가 읽을 수 없는
/// 영역이 된다. 자주 쓰는 조작이 아니므로 설정이 맞는 자리다.
///
/// **안부 확인 쉬기와 다른 것이다** -- 아래 타일의 설명을 참고.
class _DndTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final until = ref.watch(dndProvider);
    final active = until != null && until.isAfter(DateTime.now());
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(active
            ? Icons.do_not_disturb_on
            : Icons.do_not_disturb_on_outlined),
        title: const Text('제안 잠시 쉬기'),
        subtitle: Text(
          active ? '지금은 제안을 보내지 않아요' : '몇 시간 동안 제안을 멈춰요',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        trailing: TextButton(
          // 고령 사용자 기준 최소 터치 대상.
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => showDndSheet(context),
          child: Text(active ? '지금 받기' : '시간 고르기'),
        ),
      ),
    );
  }
}

class _WellnessPauseTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WellnessPauseTile> createState() => _WellnessPauseTileState();
}

class _WellnessPauseTileState extends ConsumerState<_WellnessPauseTile> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(wellnessPauseProvider.notifier).refresh();
    });
  }

  Future<void> _pick() async {
    final messenger = ScaffoldMessenger.of(context);
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: today.add(const Duration(days: 3)),
      firstDate: today,
      // 무기한을 두지 않는 것과 같은 이유로 상한도 둔다 — 꺼둔 것을 잊으면
      // 안부 기능이 있는 채로 없는 것과 같아진다.
      lastDate: today.add(const Duration(days: 90)),
      helpText: '언제까지 쉴까요?',
    );
    if (picked == null) return;
    final ok =
        await ref.read(wellnessPauseProvider.notifier).pauseUntil(picked);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 전달하지 못했어요. 연결을 확인해 주세요.')),
      );
    }
  }

  Future<void> _clear() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await ref.read(wellnessPauseProvider.notifier).clear()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 전달하지 못했어요. 연결을 확인해 주세요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final until = ref.watch(wellnessPauseProvider);
    final paused = until != null;
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          paused ? Icons.notifications_paused : Icons.favorite_outline,
        ),
        title: const Text('안부 확인 쉬기'),
        subtitle: Text(
          paused
              ? '${_ymd(until)}까지 쉬어요. 실행 실패·위험 신호음은 그대로 알려드려요.'
              : '여행처럼 집을 비우는 날 켜세요. 조용한 게 정상인 날 알림이 오지 않아요.',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        trailing: TextButton(
          // 고령 사용자 기준 최소 터치 대상.
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: paused ? _clear : _pick,
          child: Text(paused ? '지금 켜기' : '쉬기'),
        ),
      ),
    );
  }

  static String _ymd(DateTime t) => '${t.month}월 ${t.day}일';
}

// ── 데모 모드 토글 ─────────────────────────────────────────────────────────

/// 가짜 센서·가짜 결과를 화면에 주입해도 되는 상태를 켜고 끈다.
///
/// 예전에는 `kDebugMode`가 이 역할을 했는데, 그러면 실기기에 물린 디버그
/// 빌드에서도 가짜 센서가 섞여 **안 눌린 실행이 성공으로 끝난다.**
class _DemoModeTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(demoModeProvider);
    // 실행 중에는 잠근다. 모드를 갈아타면 실행 경로(실제 서버 / 모의)가
    // 통째로 바뀌는데, 그 순간 진행 중이던 작업은 추적을 잃는다.
    final phase = ref.watch(executionStatusProvider).phase;
    final busy = phase == ExecutionPhase.running ||
        phase == ExecutionPhase.retrying ||
        phase == ExecutionPhase.waiting;
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.science_outlined),
        title: const Text('데모 모드'),
        subtitle: Text(
          busy
              ? '실행이 끝난 뒤에 바꿀 수 있어요'
              : on
                  ? '실행이 서버로 나가지 않습니다 — 실제 조작이 아닙니다'
                  : '리허설용. 켜면 실행이 서버로 나가지 않습니다',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        value: on,
        onChanged: busy
            ? null
            : (v) => ref.read(demoModeProvider.notifier).set(v),
      ),
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
                    color: url != null ? context.appSuccess : context.appMuted,
                    size: 20),
                title: Text(appliance.name),
                subtitle: Text(
                  url ?? '미등록',
                  style: TextStyle(
                    color: url != null ? context.appSuccess : context.appMuted,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: Icon(
                    url != null
                        ? Icons.edit_outlined
                        : Icons.add_circle_outline,
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
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onSave(url);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = '저장 실패 — RPi 서버에 연결되어 있는지 확인하세요';
      });
    }
  }

  Future<void> _unregister() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onUnregister();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = '해제 실패';
      });
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
                  style: TextStyle(fontSize: 12, color: context.appMuted),
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
                    hintStyle: TextStyle(fontSize: 13, color: context.appMuted),
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
                    style: TextStyle(fontSize: 12, color: context.appDanger),
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
                                color:
                                    context.appDanger.withValues(alpha: 0.5)),
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

  /// 서버가 없으면 '조회 실패'가 아니라 '해당 없음'이다 -- 억제 목록은
  /// 서버가 들고 있으므로, 연결이 없을 때는 물어볼 곳 자체가 없다.
  bool _noServer = false;

  void _reload() {
    final api = ref.read(rpiApiServiceProvider);
    setState(() {
      _noServer = api == null;
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
        // '아직 못 불러왔다'와 '못 불러왔다'와 '없다'는 서로 다른 상태다.
        // 셋을 빈 목록 하나로 뭉개면, 조회가 실패한 화면이 "억제한 게 없다"고
        // 단언한다 -- 사용자가 방금 내린 제안이 사라진 것처럼 보인다.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _SuppressionNote(
            text: '불러오는 중이에요.',
            leading: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError && !_noServer) {
          return _SuppressionNote(
            text: '목록을 불러오지 못했어요.',
            leading: Icon(Icons.error_outline, size: 18),
            onRetry: _reload,
          );
        }
        final items = snapshot.data ?? const <String>[];
        if (items.isEmpty) {
          return _SuppressionNote(
            text: _noServer
                ? '기기와 연결되면 여기에 표시돼요.'
                : '다시 추천 안 하는 항목이 없어요.',
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

/// 억제 목록의 '목록 아닌 상태'(불러오는 중·실패·없음)를 같은 모양으로 그린다.
/// Colors.grey는 크림 배경 위 2.38:1이라 보조 텍스트 토큰을 쓴다(7.4:1 이상).
class _SuppressionNote extends StatelessWidget {
  const _SuppressionNote({required this.text, this.leading, this.onRetry});

  final String text;
  final Widget? leading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          if (leading != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: context.appMuted),
              child: leading!,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(text, style: TextStyle(color: context.appMuted)),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('다시 불러오기')),
        ],
      ),
    );
  }
}
