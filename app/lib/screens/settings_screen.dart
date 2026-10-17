import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/auto_rule.dart';
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
import '../providers/routine_provider.dart';
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
import '../widgets/row_menu.dart';
import '../widgets/sync_status_line.dart';
import '../widgets/thinq_discovered_section.dart';
import '../theme/app_tokens.dart';

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

/// 설정 줄 '조용한 시간'의 지금 값 — '22:00~07:00 · 켜짐'. 못 읽었으면 그렇다고 하고 할 일을 붙인다
/// (꺼짐으로 단정하지 않는다). 예전 '몰라요' 한마디는 무엇을 모르는지·어떻게 하는지 말하지 않았다(평가 3차 10/18).
/// 줄을 누르면 상세가 다시 읽는다.
String quietRowValue(QuietHoursStatus? s, {required bool hasApi}) {
  if (s == null) return hasApi ? '확인 못 했어요 · 새로 보기' : '연결 전이에요';
  return '${s.start}~${s.end} · ${s.enabled ? '켜짐' : '꺼짐'}';
}

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
        padding: const EdgeInsets.all(AppSpace.xl),
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
              title: '본체',
              // 2026-10-17 쉬운 말 사전: 폰·본체 화면 모두 '본체' — 이름 해명 문장은 뺐다.
              subtitle: _hubLine(rpi),
              onTap: () => context.push('/settings/hub'),
            ),
            _NavRow(
              icon: Icons.link,
              title: 'LG 가전 연결',
              // 확인 중·확인 실패를 '계정 연결 전'으로 말하지 않는다(외부 검토 M3, 10/15).
              subtitle: thinqApi == null || thinqAsync.hasError
                  ? '연결됐는지 몰라요'
                  : !thinqAsync.hasValue
                      ? '알아보고 있어요'
                      : thinq == null
                          ? '아직 연결 전이에요'
                          : thinq.executionMode == 'mock'
                              ? '연습으로 ${thinq.appliances.length}대 연결됐어요'
                              : '${thinq.appliances.length}대 연결됐어요',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _ThinqScreen())),
            ),
          ]),
          const SizedBox(height: AppSpace.lg),
          _NavGroup(children: [
            _NavRow(
              icon: Icons.family_restroom,
              title: '보호자 알림',
              // 조회 실패를 '아무 일 없음'(0건)처럼 말하지 않는다(2026-10-13).
              subtitle: unread > 0
                  ? '읽지 않은 알림 $unread건'
                  : care.status == CareInboxStatus.failed
                      ? '알림을 불러오지 못했어요'
                      : '새 알림이 없어요',
              badge: unread,
              onTap: () => context.push('/care'),
            ),
            _NavRow(
              icon: Icons.text_increase,
              title: '글자 크기',
              subtitle: '휴대폰 설정',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _TextSizeScreen())),
            ),
          ]),

          const SizedBox(height: AppSpace.xxxl),

          // ── 내 가전 ──────────────────────────────────────────────────────
          _SectionHeader(title: '내 가전'),
          const SizedBox(height: AppSpace.sm),
          _ApplianceSection(),
          // 가전마다 버튼을 눌러 줄 장치(노드) 등록은 개발자 탭으로 옮겼다(2026-10-14 UX) —
          // 허브가 대신 누르는 기본 구성에서는 '미연결'이 늘 보여 홈의 준비 상태와 엇갈렸다.

          const SizedBox(height: AppSpace.xxxl),

          // ── 알림 ──────────────────────────────────────────
          _SectionHeader(title: '알림'),
          const SizedBox(height: AppSpace.sm),
          // 한 줄 = 이름 + 오른쪽 지금 값(2026-10-18). 긴 설명·켜고 끄기는 줄을 눌러 상세에서.
          // 조용한 시간(2026-10-14)은 잠시 쉬기와 서버가 한 판정으로 묶는다.
          _NavGroup(children: [
            _ValueRow(
              id: 'dnd',
              icon: Icons.do_not_disturb_on_outlined,
              title: '잠시 쉬기',
              value: _dndValue(ref),
              detail: _DndTile(),
            ),
            _ValueRow(
              id: 'quiet',
              icon: Icons.bedtime_outlined,
              title: '조용한 시간',
              value: _quietValue(ref),
              // 못 읽었으면 '새로 보기' — 줄을 누르면 다시 읽는다.
              onOpen: () => ref.invalidate(quietHoursProvider),
              detail: _QuietHoursTile(),
            ),
            _ValueRow(
              id: 'wellness',
              icon: Icons.favorite_outline,
              title: kAwayTitle,
              value: _wellnessValue(ref),
              detail: _WellnessPauseTile(),
            ),
          ]),

          const SizedBox(height: AppSpace.xxxl),

          // ── 제안 ──────────────────────────────────────────
          _SectionHeader(title: '물어보기'),
          const SizedBox(height: AppSpace.sm),
          _NavGroup(children: [
          _NavRow(
            icon: Icons.history,
            title: '생활 습관 알아가기',
            subtitle: '보기',
            onTap: () {
              final api = ref.read(rpiApiServiceProvider);
              final appliances = ref.read(installedAppliancesProvider);
              showDialog<void>(context: context, builder: (_) => LearningStatusDialog(
                load: api?.learningStatus,
                applianceNames: {for (final a in appliances) a.id: a.name},
              ));
            },
          ),
          ]),
          _SuppressionSection(),

          const SizedBox(height: AppSpace.xxxl),

          // ── 화면·소리 ────────────────────────────────────────────────────
          _SectionHeader(title: '화면·소리'),
          const SizedBox(height: AppSpace.xs),
          _ThemeToggleTile(),
          _VoiceGuideTile(),

          const SizedBox(height: AppSpace.xxxl),
          _NavGroup(children: [
            _NavRow(
              icon: Icons.info_outline,
              title: '앱 정보',
              subtitle: '날씨 출처와 이용 허락',
              onTap: () => context.push('/settings/info'),
            ),
            // 개발자 도구 — 탭이 아니라 맨 아래 항목(2026-10-18). 서버 개발자 모드일 때만 보인다.
            if (ref.watch(showDeveloperTabProvider))
              _NavRow(
                key: const Key('settings-developer'),
                icon: Icons.build_outlined,
                title: '개발자',
                subtitle: '설치·시험용 도구. 시연 전에 꺼 주세요',
                onTap: () => context.push('/dev'),
              ),
          ]),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// 잠시 쉬기의 지금 값 — 꺼짐 / 'HH:MM까지'.
  static String _dndValue(WidgetRef ref) {
    final until = ref.watch(dndProvider);
    return until != null && until.isAfter(DateTime.now()) ? '${pauseEndClock(until)}까지' : '꺼짐';
  }

  /// 조용한 시간의 지금 값 — [quietRowValue].
  static String _quietValue(WidgetRef ref) => quietRowValue(
      ref.watch(quietHoursProvider).valueOrNull,
      hasApi: ref.watch(rpiApiServiceProvider) != null);

  /// 집 비우는 날의 지금 값 — 꺼짐 / 'M월 D일까지'.
  static String _wellnessValue(WidgetRef ref) {
    final until = ref.watch(wellnessPauseProvider);
    return until == null ? '꺼짐' : '${until.month}월 ${until.day}일까지';
  }

  static String _hubLine(RpiConnectionState state) => switch (state) {
        RpiConnectionState.connected => '연결됐어요',
        RpiConnectionState.keyRequired => '연결 비밀번호가 필요해요',
        RpiConnectionState.checking => '확인하는 중이에요',
        RpiConnectionState.unreachable => '연결이 끊겼어요',
        RpiConnectionState.unconfigured => '아직 주소가 없어요',
      };
}
