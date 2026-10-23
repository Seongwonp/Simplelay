import '../models/clock_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/auto_rule.dart';
import '../models/display_status.dart';
import '../models/line_break.dart';
import 'home_screen.dart' show careNeedsLook;
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
import '../theme/app_icons.dart';
import '../theme/app_text.dart';

import 'help_screen.dart';
import '../widgets/dnd_bottom_sheet.dart';
import '../widgets/learning_status_dialog.dart';
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

/// 설정 줄 '조용한 시간'의 지금 값 — 켜져 있으면 '오후 10:00~오전 7:00', 꺼져 있으면 '꺼짐'. 못 읽었으면 그렇다고 하고 할 일을 붙인다
/// (꺼짐으로 단정하지 않는다). 예전 '확인하지 못했어요' 한마디는 무엇을 모르는지·어떻게 하는지 말하지 않았다(평가 3차 10/18).
/// 줄을 누르면 상세가 다시 읽는다.
///
/// 평가 10차(10/18): '확인 못 했어요 · 새로 보기'는 까닭이 없었고 '새로 보기'가 값처럼 붙어 있었다 → 까닭은 본체 연결
/// 상태로 알 때만 앞에 붙이고([hubReadFailReason]), '새로 보기'는 줄 아래 따로 단추([kRefreshLabel]).
String quietRowValue(QuietHoursStatus? s,
    {required bool hasApi, RpiConnectionState? hub, bool loading = false}) {
  if (s == null) {
    if (!hasApi) return '연결 전이에요';
    if (loading) return '알아보고 있어요';
    return readFailText(hub);
  }
  // 평가 15차(10/18): '오후 10:00~오전 7:00 · 꺼짐'은 이름 옆에 다 들어가지 않아 이 줄만 값이 아랫줄로 내려갔다 →
  // 다른 두 줄(잠시 쉬기·집 비우는 날)과 같은 꼴: 꺼져 있으면 '꺼짐', 켜져 있으면 언제인지(시각 범위). 시각은 상세에서도 본다.
  return s.enabled ? ampmRange(s.start, s.end) : '꺼짐';
}

/// 못 읽은 값의 다시 읽기 단추 이름.
const kRefreshLabel = '새로 보기';

/// 본체에서 값을 못 읽은 까닭 — 연결 상태로 **알 때만**('본체와 연결이 끊겨'). 확인 중·연결됨이면 null(까닭을 지어내지 않는다).
String? hubReadFailReason(RpiConnectionState? hub) => switch (hub) {
      RpiConnectionState.unreachable => '본체와 연결이 끊겨',
      RpiConnectionState.keyRequired => '연결 비밀번호가 없어',
      RpiConnectionState.unconfigured => '본체 주소가 없어',
      _ => null,
    };

/// '못 불러왔어요' — 까닭을 알면 앞에('본체와 연결이 끊겨 못 불러왔어요').
String readFailText(RpiConnectionState? hub) {
  final why = hubReadFailReason(hub);
  return why == null ? '못 불러왔어요' : '$why 못 불러왔어요';
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
      // 모든 줄이 같은 아이콘 열·화살표 열(평가 15차 10/18) — [settingsListTileTheme].
      body: ListTileTheme(
        data: settingsListTileTheme(context),
        child: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          if (ref.watch(demoModeProvider))
            ListTile(title: const Text('연습으로 쓰는 중이에요'),
              trailing: TextButton(onPressed: () => ref.read(demoModeProvider.notifier).set(false),
                child: const Text('연습 끝내기'))),
          // 본체에 닿지 않으면 까닭을 위에 한 번(휴리스틱 평가 10/18: '본체와 연결이 끊겨 못 불러왔어요'가 줄마다 되풀이됐다).
          // 줄에는 '못 불러왔어요'만.
          if (hubReadFailReason(rpi) case final why?)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: Container(
                key: const Key('settings-hub-banner'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: context.appWarning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.appWarning.withValues(alpha: 0.35)),
                ),
                child: Row(children: [
                  Icon(Icons.wifi_off, size: AppSpace.xl, color: context.appWarning),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(keepWordsTogether('$why 일부 값을 못 불러왔어요'),
                        semanticsLabel: '$why 일부 값을 못 불러왔어요',
                        style: TextStyle(
                            fontSize: AppFont.caption, fontWeight: FontWeight.w600, color: context.appWarning)),
                  ),
                ]),
              ),
            ),
          // 위 두 묶음이 UI 확정 §2의 설정 탭이다: 가전 추가 · 허브 · LG ThinQ
          // 연결 / 음성으로 멈추기 · 보호자 알림 · 글자 크기. 그 아래는 예전
          // 설정의 세부(가전 관리·알림·제안·화면)를 그대로 둔다 -- 기능을 잃지
          // 않는다. 서버 주소·API 키·예비 연결은 '허브' 안으로, 데모·개발자
          // 도구는 개발자 탭으로 옮겼다.
          _NavGroup(children: [
            _NavRow(
              // 평가 17차(10/18): 화면 달린 기기 그림(tablet)이 빈 네모처럼 보여 깨진 아이콘으로 읽혔다 → 집 안 기기를
              // 잇는 본체 모양(router).
              icon: Icons.router_outlined,
              title: '본체',
              // 2026-10-17 쉬운 말 사전: 폰·본체 화면 모두 '본체' — 이름 해명 문장은 뺐다.
              subtitle: _hubLine(rpi),
              onTap: () => context.push('/settings/hub'),
            ),
            _NavRow(
              icon: Icons.link,
              title: 'LG 가전 연결',
              // 확인 중·확인 실패를 '계정 연결 전'으로 말하지 않는다(외부 검토 M3, 10/15).
              // 평가 10차(10/18): '연결됐는지 확인하지 못했어요'에 까닭이 없었다 — 본체 연결 상태로 알 때만 까닭을 붙인다.
              subtitle: thinqApi == null
                  ? '본체를 연결하면 볼 수 있어요'
                  : thinqAsync.hasError
                  ? readFailText(null)
                  : !thinqAsync.hasValue
                      ? '알아보고 있어요'
                      : thinq == null
                          ? '아직 연결 전이에요'
                          : thinq.executionMode == 'mock'
                              ? '연습으로 ${thinq.appliances.length}대 연결됨'
                              : '${thinq.appliances.length}대 연결됨',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _ThinqScreen())),
            ),
            // 평가 16차(10/18): 'LG 가전 연결'과 '보호자 알림' 사이에만 구분선 없이 빈칸이 있었다 → 한 묶음, 구분선 규칙 하나.
            _NavRow(
              icon: Icons.family_restroom,
              title: '보호자 알림',
              // 조회 실패를 '아무 일 없음'(0건)처럼 말하지 않는다(2026-10-13).
              // 평가 13차(10/18): 홈 줄과 같은 이름 '안 본 알림 N건'. 빨간 배지는 실패·정지 같은 볼 것이 섞였을 때만.
              // 10/18 §3-5: '새 알림이 없어요'(0건 단정)는 본체에 닿고 조회가 성공했을 때만. 본체와 끊겼거나(전에 받은 0건이
              // 남아 있어도) 조회가 실패했으면 모르는 것이다 — LG 가전 줄과 같은 '못 불러왔어요'.
              subtitle: unread > 0
                  ? '안 본 알림 $unread건'
                  : care.status == CareInboxStatus.failed ||
                          care.status == CareInboxStatus.unconfigured ||
                          hubReadFailReason(rpi) != null
                      ? readFailText(null)
                      : care.status == CareInboxStatus.loading
                          ? '알아보고 있어요'
                          : '새 알림이 없어요',
              // 평가 15차(10/18): 빨간 숫자 칩과 '안 본 알림 7건' 글자가 같은 말을 두 번 했다 → 글자 하나, 볼 것(실패·정지
              // 같은)이 섞였을 때만 그 글자를 경고색으로. 탭 막대의 점은 그대로 알린다.
              valueColor: unread > 0 && careNeedsLook(care.unreadEvents) ? context.appWarning : null,
              onTap: () => context.push('/care'),
            ),
            _NavRow(
              icon: Icons.text_increase,
              title: '글자 크기',
              subtitle: '휴대폰 설정',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const _TextSizeScreen())),
            ),
            // 도움말 입구(휴리스틱 평가 10/18 — 처음 쓰는 사람이 볼 곳이 없었다).
            _NavRow(
              key: const Key('settings-help'),
              icon: Icons.help_outline,
              title: '사용 방법',
              subtitle: '멈추는 법 · 연습',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const HelpScreen())),
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
              icon: AppIcons.pause,
              title: '방해 금지',
              value: _dndValue(ref),
              detail: _DndTile(),
            ),
            _ValueRow(
              id: 'quiet',
              icon: AppIcons.quietHours,
              title: '조용한 시간',
              value: _quietValue(ref),
              // 줄을 누르면 상세가 다시 읽는다. 못 읽었으면 줄 아래 '새로 보기' 단추를 따로 둔다(평가 10차 10/18).
              onOpen: () => ref.invalidate(quietHoursProvider),
              action: _quietFailed(ref)
                  ? TextButton.icon(
                      key: const Key('settings-quiet-refresh'),
                      onPressed: () => ref.invalidate(quietHoursProvider),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text(kRefreshLabel),
                    )
                  : null,
              detail: _QuietHoursTile(),
            ),
            _ValueRow(
              id: 'wellness',
              // 평가 14차(10/18): 하트는 뜻이 없었다 → 집을 비우는 날(여행 가방).
              icon: Icons.luggage_outlined,
              title: kAwayTitle,
              value: _wellnessValue(ref),
              detail: _WellnessPauseTile(),
            ),
          ]),

          const SizedBox(height: AppSpace.xxxl),

          // ── 생활 습관 ──────────────────────────────────────
          // 평가 4차 10/18: '물어보기' 섹션 아래 '생활 습관 알아가기'가 어긋났다. 이 구획의 두 가지 — 알아 둔 습관 보기,
          // 그만 묻기로 한 것 다시 받기 — 는 모두 '습관을 보고 묻는 일'에 관한 것이라 섹션 이름을 '생활 습관'으로 합친다.
          _SectionHeader(title: '생활 습관'),
          const SizedBox(height: AppSpace.sm),
          _NavGroup(children: [
          _NavRow(
            icon: Icons.history,
            title: '알아 둔 습관',
            subtitle: '자주 하신 일',
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
            // 개발자 도구 — 탭이 아니라 맨 아래 항목(2026-10-18). 서버 개발자 모드이고, 앱 정보에서 열었을 때만
            // 보인다(평가 17차 10/18: 가족에게 그대로 보였다 — [developerUnlockedProvider]).
            if (ref.watch(showDeveloperTabProvider) && ref.watch(developerUnlockedProvider))
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
      ),
    );
  }

  /// 잠시 쉬기의 지금 값 — 꺼짐 / 'HH:MM까지'.
  static String _dndValue(WidgetRef ref) {
    final until = ref.watch(dndProvider);
    return until != null && until.isAfter(DateTime.now()) ? '${pauseEndClock(until)}까지' : '꺼짐';
  }

  /// 조용한 시간의 지금 값 — [quietRowValue].
  static String _quietValue(WidgetRef ref) {
    final q = ref.watch(quietHoursProvider);
    return quietRowValue(q.valueOrNull,
        hasApi: ref.watch(rpiApiServiceProvider) != null,
        // 까닭(본체와 끊김)은 설정 맨 위 배너가 한 번 말한다(휴리스틱 평가 10/18) — 줄마다 되풀이하지 않는다.
        loading: q.isLoading && !q.hasValue);
  }

  /// 조용한 시간을 본체에서 못 읽었다(다 읽고도 값이 없다) — '새로 보기' 단추를 둔다.
  static bool _quietFailed(WidgetRef ref) {
    final q = ref.watch(quietHoursProvider);
    return ref.watch(rpiApiServiceProvider) != null && !q.isLoading && q.valueOrNull == null;
  }

  /// 집 비우는 날의 지금 값 — 꺼짐 / 'M월 D일까지'.
  static String _wellnessValue(WidgetRef ref) {
    final until = ref.watch(wellnessPauseProvider);
    return until == null ? '꺼짐' : '${until.month}월 ${until.day}일까지';
  }

  static String _hubLine(RpiConnectionState state) => switch (state) {
        RpiConnectionState.connected => '연결됨',
        RpiConnectionState.keyRequired => '연결 비밀번호가 필요해요',
        RpiConnectionState.checking => '알아보고 있어요',
        RpiConnectionState.unreachable => '연결이 끊겼어요',
        RpiConnectionState.unconfigured => '아직 주소가 없어요',
      };
}
