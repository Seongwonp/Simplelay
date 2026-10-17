import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/display_status.dart';
import '../models/line_break.dart';
import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../models/execution_status.dart';
import '../models/quiet_hours.dart';
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
import '../widgets/sync_status_line.dart';
import '../widgets/thinq_discovered_section.dart';

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
    final care = ref.watch(careEventsProvider);
    final unread = care.unreadCount;
    final thinqAsync = ref.watch(thinqOverviewProvider);
    final thinq = thinqAsync.valueOrNull;
    final thinqApi = ref.watch(rpiApiServiceProvider);
    return Scaffold(
      // 탭 제목은 홈('우리 집')과 같은 굵은 큰 제목(UI 평가 10/17).
      appBar: AppBar(title: Text('설정', style: AppText.heading)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (ref.watch(demoModeProvider))
            ListTile(title: const Text('연습으로 쓰는 중이에요'),
              trailing: TextButton(onPressed: () => ref.read(demoModeProvider.notifier).set(false),
                child: const Text('연습 끝내기'))),
          // 위 두 묶음이 UI 확정 §2의 설정 탭이다: 가전 추가 · 허브 · LG ThinQ
          // 연결 / 음성으로 멈추기 · 보호자 알림 · 글자 크기. 그 아래는 예전
          // 설정의 세부(가전 관리·알림·제안·화면)를 그대로 둔다 -- 기능을 잃지
          // 않는다. 서버 주소·API 키·예비 연결은 '허브' 안으로, 데모·개발자
          // 도구는 개발자 탭으로 옮겼다.
          _NavGroup(children: [
            _NavRow(
              icon: Icons.hub_outlined,
              title: '허브',
              // 같은 물건을 키오스크는 다른 이름으로 부른다 — 처음 한 번 이어 준다(2026-10-15 안 A).
              subtitle: "${_hubLine(rpi)} · 키오스크에서는 'SimpleLay 본체'라고 불러요",
              onTap: () => context.push('/settings/hub'),
            ),
            _NavRow(
              icon: Icons.link,
              title: 'LG ThinQ 연결',
              // 확인 중·확인 실패를 '계정 연결 전'으로 말하지 않는다(외부 검토 M3, 10/15).
              subtitle: thinqApi == null || thinqAsync.hasError
                  ? '연결 상태 확인 못 함'
                  : !thinqAsync.hasValue
                      ? '확인 중'
                      : thinq == null
                          ? '계정 연결 전'
                          : thinq.executionMode == 'mock'
                              ? '연습 연결 · ${thinq.appliances.length}대'
                              : '연결됨 · ${thinq.appliances.length}대',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _ThinqScreen())),
            ),
          ]),
          const SizedBox(height: 16),
          _NavGroup(children: [
            _NavRow(
              icon: Icons.family_restroom,
              title: '보호자 알림',
              // 조회 실패를 '아무 일 없음'(0건)처럼 말하지 않는다(2026-10-13).
              subtitle: unread > 0
                  ? '읽지 않은 알림 $unread건'
                  : care.status == CareInboxStatus.failed
                      ? '알림을 불러오지 못했어요'
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
          // 가전마다 버튼을 눌러 줄 장치(노드) 등록은 개발자 탭으로 옮겼다(2026-10-14 UX) —
          // 허브가 대신 누르는 기본 구성에서는 '미연결'이 늘 보여 홈의 준비 상태와 엇갈렸다.

          const SizedBox(height: 28),

          // ── 알림 ──────────────────────────────────────────
          _SectionHeader(title: '알림'),
          const SizedBox(height: 4),
          _DndTile(),
          // 조용한 시간(2026-10-14) — 새 탭 없이 이 구획 안. 잠시 쉬기와 서버가 한 판정으로 묶는다.
          _QuietHoursTile(),
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
        RpiConnectionState.connected => '연결됨',
        RpiConnectionState.keyRequired => '허브 키가 필요해요',
        RpiConnectionState.checking => '확인하는 중이에요',
        RpiConnectionState.unreachable => '지금은 닿지 않아요',
        RpiConnectionState.unconfigured => '아직 주소가 없어요',
      };
}
