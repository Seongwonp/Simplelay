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
import '../theme/app_text.dart';

import '../widgets/dnd_bottom_sheet.dart';
import '../widgets/sync_status_line.dart';

// 구획별 파일. `part`라서 private 이름·import·provider 읽는 시점이 이 파일에
// 있을 때와 완전히 같다 -- 동작을 바꾸지 않는 이동만 했다. 개발자 도구는
// `settings/developer_section.dart`에 들어간다.
part 'settings/settings_row.dart';
part 'settings/accessibility_section.dart';
part 'settings/developer_section.dart';
part 'settings/connection_section.dart';
part 'settings/notification_section.dart';

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
          // 순서가 곧 이 화면의 주장이다: **무엇을 조작하는가 → 그것이 이어져
          // 있는가 → 언제 말을 걸지 → 화면·소리 → (접힌) 기술 상세.** 예전에는
          // 다크 모드가 맨 위였고, 정작 가전과 연결은 아래로 밀려 있었다.
          // 항목을 카드로 감싸지 않는다 -- 제목·행·구분선으로 구획한다.

          // ── 가전 ─────────────────────────────────────────────────────────
          _SectionHeader(title: '가전'),
          const SizedBox(height: 8),
          _ApplianceSection(),
          const SizedBox(height: 16),
          // 가전마다 버튼을 대신 눌러 줄 장치가 붙어 있는지.
          _NodeSection(),

          const SizedBox(height: 28),

          // ── 연결 ─────────────────────────────────────────────────────────
          _SectionHeader(title: '연결'),
          const SizedBox(height: 4),
          _RpiConnectionTile(),
          _SavedDeviceSection(),

          const SizedBox(height: 28),

          // ── 알림 ──────────────────────────────────────────
          _SectionHeader(title: '알림'),
          const SizedBox(height: 4),
          _DndTile(),
          _WellnessPauseTile(),

          const SizedBox(height: 28),

          // ── 제안 ──────────────────────────────────────────
          _SectionHeader(title: '제안'),
          const SizedBox(height: 8),
          _SuppressionSection(),

          const SizedBox(height: 28),

          // ── 화면·소리 ────────────────────────────────────────────────────
          _SectionHeader(title: '화면·소리'),
          const SizedBox(height: 4),
          _ThemeToggleTile(),
          _VoiceGuideTile(),

          const SizedBox(height: 20),
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
                    style: TextStyle(color: context.appMuted, fontSize: 15),
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

// ── 가전 선택 ─────────────────────────────────────────────────────────────

class _ApplianceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedApplianceProvider);
    // 여기는 **이 폰에 설치된 가전**만 고른다. 예시 템플릿을 섞으면 아직
    // 아무것도 등록하지 않은 사람에게 전자레인지가 이미 있는 것처럼 보인다.
    final appliances = ref.watch(installedAppliancesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('제어 가전'),
        const SizedBox(height: 10),
        // 0대는 오류가 아니다. 고를 것이 없다는 사실과 어디서 만드는지만
        // 말하고, 선택 칩 자리를 비워 두지 않는다.
        if (appliances.isEmpty)
          _EmptyApplianceRow(onAdd: () => context.push('/appliance/new'))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...appliances.map((appliance) {
                final isSelected = appliance.id == selected?.id;
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
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
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
                            appliance.displayName,
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

/// 설치한 가전이 0대일 때 '제어 가전' 자리에 놓는 줄.
class _EmptyApplianceRow extends StatelessWidget {
  const _EmptyApplianceRow({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              '아직 추가한 가전이 없어요.',
              style: TextStyle(color: context.appMuted, fontSize: 13),
            ),
          ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('가전 추가'),
          ),
        ],
      );
}

// ── ESP32 노드 등록 ───────────────────────────────────────────────────────

class _NodeSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(installedAppliancesProvider);
    final nodesAsync = ref.watch(nodeRegistryProvider);
    // 등록할 가전이 없으면 노드 목록을 부를 이유도 없다.
    if (appliances.isEmpty) {
      return _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.add_home_outlined, color: context.appMuted, size: 20),
          title: const Text('등록할 가전이 아직 없어요'),
          subtitle: Text(
            '가전을 추가하면 여기서 버튼을 눌러 줄 장치를 잇습니다.',
            style: TextStyle(color: context.appMuted, fontSize: 14),
          ),
        ),
      );
    }

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
          title: Text('가전 연결 상태를 불러오지 못했어요',
              style: TextStyle(color: context.appMuted, fontSize: 14)),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
            onPressed: () => ref.invalidate(nodeRegistryProvider),
          ),
        ),
      ),
      data: (nodes) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '가전마다 버튼을 눌러 줄 장치',
              style: TextStyle(fontSize: 15, color: context.appMuted),
            ),
          ),
          ...appliances.map((appliance) {
            final url = nodes[appliance.id];
            return _SettingCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(appliance.icon,
                    color: url != null ? context.appSuccess : context.appMuted,
                    size: 20),
                title: Text(appliance.displayName),
                // 주소는 편집 시트에서만. 목록에서는 이어졌는지만 말한다.
                subtitle: Text(
                  url != null ? '장치가 이어져 있어요' : '아직 장치가 없어요',
                  style: TextStyle(
                    color: url != null ? context.appSuccess : context.appMuted,
                    fontSize: 14,
                  ),
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
            );
          }),
        ],
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
