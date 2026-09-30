import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../models/execution_status.dart';
import '../providers/appliance_sync_provider.dart';
import '../providers/care_events_provider.dart';
import '../providers/hub_provider.dart';
import '../services/location_service.dart';
import '../providers/wellness_pause_provider.dart';
import '../providers/demo_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/tts_provider.dart';
import '../services/ble_service.dart';
import '../services/demo_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

import '../widgets/dnd_bottom_sheet.dart';
import '../widgets/learning_status_dialog.dart';
import '../widgets/route_badge.dart';
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
part 'settings/nav_rows.dart';
part 'settings/hub_screen.dart';
part 'settings/developer_tab.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rpi = ref.watch(rpiConnectionProvider);
    final unread = ref.watch(careEventsProvider).unreadCount;
    final thinq = ref.watch(thinqOverviewProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 위 두 묶음이 UI 확정 §2의 설정 탭이다: 가전 추가 · 허브 · LG ThinQ
          // 연결 / 음성으로 멈추기 · 보호자 알림 · 글자 크기. 그 아래는 예전
          // 설정의 세부(가전 관리·알림·제안·화면)를 그대로 둔다 -- 기능을 잃지
          // 않는다. 서버 주소·API 키·예비 연결은 '허브' 안으로, 데모·개발자
          // 도구는 개발자 탭으로 옮겼다.
          _NavGroup(children: [
            _NavRow(
              icon: Icons.add_a_photo_outlined,
              title: '가전 추가',
              subtitle: '사진을 찍고 버튼을 짚어 등록',
              onTap: () => context.push('/appliance/add'),
            ),
            _NavRow(
              icon: Icons.hub_outlined,
              title: '허브',
              subtitle: _hubLine(rpi),
              onTap: () => context.push('/settings/hub'),
            ),
            _NavRow(
              icon: Icons.link,
              title: 'LG ThinQ 연결',
              subtitle: thinq == null
                  ? '계정 연결 전'
                  : thinq.executionMode == 'mock'
                      ? '모의 연결(실제 가전 아님) · ${thinq.appliances.length}대'
                      : '연결됨 · ${thinq.appliances.length}대',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _ThinqScreen())),
            ),
          ]),
          const SizedBox(height: 16),
          _NavGroup(children: [
            _NavRow(
              icon: Icons.mic_none,
              title: '음성으로 멈추기',
              subtitle: '동작 중에만 "멈춰"를 들어요',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _VoiceStopScreen())),
            ),
            _NavRow(
              icon: Icons.family_restroom,
              title: '보호자 알림',
              subtitle: unread > 0
                  ? '읽지 않은 알림 $unread건'
                  : '확인이 없으면 알림을 보내요',
              badge: unread,
              onTap: () => context.push('/care'),
            ),
            _NavRow(
              icon: Icons.text_increase,
              title: '글자 크기',
              subtitle: '휴대폰 글자 크기를 따라요',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _TextSizeScreen())),
            ),
          ]),

          const SizedBox(height: 28),

          // ── 내 가전 ──────────────────────────────────────────────────────
          _SectionHeader(title: '내 가전'),
          const SizedBox(height: 8),
          _ApplianceSection(),
          const SizedBox(height: 16),
          // 가전마다 버튼을 대신 눌러 줄 장치가 붙어 있는지.
          _NodeSection(),

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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: const Text('생활 습관 알아가기'),
            subtitle: const Text('기억한 습관과 추천 근거 확인'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final api = ref.read(rpiApiServiceProvider);
              final appliances = ref.read(installedAppliancesProvider);
              showDialog<void>(context: context, builder: (_) => LearningStatusDialog(
                load: api?.learningStatus,
                applianceNames: {for (final a in appliances) a.id: a.name},
              ));
            },
          ),
          _SuppressionSection(),

          const SizedBox(height: 28),

          // ── 화면·소리 ────────────────────────────────────────────────────
          _SectionHeader(title: '화면·소리'),
          const SizedBox(height: 4),
          _ThemeToggleTile(),
          _VoiceGuideTile(),

          const SizedBox(height: 28),
          _NavGroup(children: [
            _NavRow(
              icon: Icons.info_outline,
              title: '앱 정보',
              subtitle: '날씨 출처와 이용 허락',
              onTap: () => context.push('/settings/info'),
            ),
          ]),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  static String _hubLine(RpiConnectionState state) => switch (state) {
        RpiConnectionState.connected => '연결됨 · 위치와 주소 설정',
        RpiConnectionState.checking => '확인하는 중이에요',
        RpiConnectionState.unreachable => '지금은 닿지 않아요',
        RpiConnectionState.unconfigured => '아직 주소가 없어요',
      };
}
