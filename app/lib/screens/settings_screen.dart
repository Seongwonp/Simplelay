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
part 'settings/appliance_section.dart';
part 'settings/node_section.dart';

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

          // ── 개발자 ────────────────────────────────────────────────────────
          if (_showAdvanced) ...[
            const SizedBox(height: 24),
            _SectionHeader(title: '개발자'),
            const SizedBox(height: 4),
            _DeveloperToolsTile(),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
