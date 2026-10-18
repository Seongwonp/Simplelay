import 'dart:async';

import 'package:routine_rehearsal/routine_rehearsal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/display_status.dart';
import '../models/hub.dart' show VerifyPassLookup;
import '../models/line_break.dart';
import '../models/quiet_hours.dart' show kSettingNotSavedNotice, pauseEndClock;
import '../models/routine.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/routine_provider.dart';
import '../widgets/routine_icon.dart';
import '../widgets/routine_run.dart';
import 'routines_screen.dart' show ampmClock, kSetupActionLabel, routineSubtitle, withAmPm;
import 'history_screen.dart' show historyFailedOnlyProvider;
import '../providers/ble_provider.dart';
import '../providers/care_events_provider.dart';
import '../providers/estop_provider.dart';
import '../providers/execution_status_provider.dart';
import '../widgets/demo_badge.dart';
import '../widgets/appliance_setup_card.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_icons.dart';
import '../widgets/skip_next_control.dart';
import '../widgets/status_badge.dart';
import '../models/execution_status.dart';
import '../theme/app_tokens.dart';

// 사진 패널의 테스트 이미지 구멍은 사진을 그리는 위젯 쪽에 있다. 예전 경로
// (home_screen.dart)로 쓰던 테스트가 그대로 쓰도록 다시 내보낸다.
export '../widgets/panel_photo_view.dart' show applianceImageOverride;



/// 홈 — "우리 집"(UI 개편안 §4 폰 홈, 2026-10-18).
///
/// 읽는 순서: **실패 경고(있을 때만) → 지금 우리 집(공기·다음 예정) → 지금 할 일(제안, 있을 때) →
/// 해야 할 일·안 본 알림(있을 때만) → 가전(상태 한 줄) → 내 루틴 타일.**
/// 채운 주 버튼은 제안의 '지금 하기' 하나다. 큰 '바로 실행할 수 있는 루틴' 카드는 없다
/// — 같은 루틴이 큰 카드·줄·다음 실행으로 세 번 나왔다(2차 평가 10/18).
///
/// 가전 카드를 눌러도 **실행하지 않는다.** 상세만 열리고, 누르는 일은 늘
/// 확인을 한 번 더 거친다. 루틴 타일도 승인 카드만 만든다.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final rpiState = ref.watch(rpiConnectionProvider);
    final suggestions = ref.watch(suggestionProvider);
    final dndUntil = ref.watch(dndProvider);
    final sensorAsync = ref.watch(sensorProvider);
    final execution = ref.watch(executionStatusProvider);

    // 허브 연결은 그대로인데 로컬 실행 대상의 걸림·링크가 바뀌면(비상정지 걸림·해제,
    // 누름 장치 링크 끊김·복구) 타일의 준비 판정도 바뀌었을 수 있다 — 가전 목록을 다시
    // 받는다(검토 M1, 2026-10-13). 다시 받는 동안 목록은 loading이라 타일이 예전 긍정을
    // 쓰지 않는다. 어느 가전이 막히는지는 서버(`readiness_view`)가 정한다 — 폰이 모의·
    // ThinQ까지 일괄로 막지 않는다. 처음 받은 값(null → 값)은 변화로 세지 않는다.
    ref.listen<({bool? estop, bool? linkUp})?>(
        estopProvider.select((s) => s.localGate), (prev, next) {
      if (prev == null || next == null || prev == next) return;
      final catalog = ref.read(serverApplianceCatalogProvider.notifier);
      Future.microtask(() {
        if (catalog.mounted) catalog.refresh();
      });
    });

    final connected = connection == BleConnectionState.connected;
    final dndActive = dndUntil != null && dndUntil.isAfter(DateTime.now());

    // 홈은 **이 폰에 설치된 가전**만 센다. 예시 템플릿을 섞어 세면 아직
    // 아무것도 등록하지 않은 사람의 홈에 남의 가전이 놓인다.
    final appliances = ref.watch(installedAppliancesProvider);

    // 연결 문제는 **정도에 따라 자리가 다르다.** 기기(서버)에 닿지 않으면
    // 제안·기록·실행 상태가 모두 멈추므로 맨 위에서 먼저 말한다. 예비
    // 연결만 꺼진 것은 지금 조작에 지장이 없으니 아래에 조용히 둔다.
    //
    // **확인 중은 끊김이 아니다.** 닿지 않는다고 확인된 경우(unreachable)에만
    // 경고한다(로그 ac #5).
    final serverDown = rpiState == RpiConnectionState.unreachable;
    final connectionDetails =
        _ConnectionDetails(rpiState: rpiState, bleConnected: connected);

    // 제안은 **한 번에 하나만**(UI 확정 §1-2). 처리하면 다음 것이 올라온다.
    final suggestion = suggestions.firstOrNull;
    final catalog = ref.watch(serverApplianceCatalogProvider);
    // 본체가 읽은 LG 가전 전원(서버 전원 기억 — 클라우드를 부르지 않는다). 모르는 가전은 없다.
    final thinqPower =
        ref.watch(thinqPowerProvider).valueOrNull ?? const <String, String>{};

    // 타일의 '확인 주행' 보조 줄(2026-10-13, 표시만). 보조 줄을 붙일 타일만
    // 확인 주행을 묻는다 — 위치 미설정·허브 장애 타일은 묻지도 않는다.
    String? verifyNoteOf(ApplianceMap a) {
      String? note(VerifyPassLookup lookup) => verifyPassTileNote(
          appliance: a, hub: rpiState, catalog: catalog.status, lookup: lookup);
      if (note(const VerifyPassLookup.unknown()) == null) return null;
      // 다시 묻는 중에는 예전 결과 대신 모름(검토 M3).
      return note(setupPassLookupOf(ref.watch(setupPassProvider(a.id))));
    }

    final verifyNotes = {for (final a in appliances) a.id: verifyNoteOf(a)};
    final setupCandidates = [
      for (final a in appliances)
        if (a.isCustom && !a.isDemo && !a.isThinq) a,
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxxl),
          children: [
            _Header(
              rpiState: rpiState,
              backupOnly: connected,
              onVoice: () => context.go('/voice'),
            ),
            const SizedBox(height: AppSpace.lg),

            // ── 연결 문제(기기에 닿지 않을 때만 맨 위) ──────────────────────
            if (serverDown) ...[
              connectionDetails,
              const SizedBox(height: AppSpace.md),
            ],

            // ── 잠시 쉬기 배너 ─────────────────────────────────────────────
            if (dndActive) ...[
              _DndBanner(
                until: dndUntil,
                onClear: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await ref.read(dndProvider.notifier).clear() == false) {
                    messenger.showSnackBar(const SnackBar(content: Text(kSettingNotSavedNotice)));
                  }
                },
              ),
              const SizedBox(height: AppSpace.lg),
            ],

            // ── 실패 경고(있을 때만, 맨 위 따로 — 휴리스틱 평가 10/18) ─────────────────
            _FailureAlert(execution: execution),

            // ── 지금 우리 집 ─────────────────────────────────────────────
            const _HomeNow(),

            // ── ① 지금 할 일 ──────────────────────────────────────────────
            // 빈 제안 문장("지금 확인할 제안이 없어요")은 두지 않는다(2026-10-13).
            if (suggestion != null) ...[
              _SuggestionCard(
                key: ValueKey(suggestion.sequenceId),
                suggestion: suggestion,
                appliance: appliances
                    .where((a) => a.id == suggestion.applianceId)
                    .firstOrNull,
                onRun: () => context.push('/suggestion/${suggestion.sequenceId}'),
                onLater: () => _later(context, ref, suggestion),
              ),
              const SizedBox(height: AppSpace.xxl),
            ],

            // ── ② 해야 할 일(설정 남음)·안 본 알림(설정과 같은 수) ─────────────────────
            _TodoAndUnread(setupCandidates: setupCandidates),

            // ── ③ 가전 ────────────────────────────────────────────────────
            _SectionTitle('가전', key: const Key('home-appliances')),
            if (appliances.isEmpty)
              _NoApplianceStage(
                onAdd: () => context.push('/appliance/add'),
                note: _serverCatalogNote(catalog),
              )
            else
              _ApplianceGrid(
                appliances: appliances,
                statusOf: (a) => applianceTileStatus(
                  appliance: a,
                  readinessSource: _readinessSource(a, catalog),
                  hub: rpiState,
                  catalog: catalog.status,
                  execution: execution,
                  thinqOn: thinqPower[a.id] == 'on',
                  thinqOff: thinqPower[a.id] == 'off',
                ),
                verifyNoteOf: (a) => verifyNotes[a.id],
                onOpen: (a) {
                  ref.read(selectedApplianceProvider.notifier).select(a);
                  context.push('/appliance/detail/${a.id}');
                },
                onAdd: () => context.push('/appliance/add'),
              ),

            // ── ④ 내 루틴 타일 ─────────────────────────────────────────────
            _HomeRoutines(
              hubConnected: rpiState == RpiConnectionState.connected,
              hasAppliances: appliances.isNotEmpty,
              applianceNames: {for (final a in appliances) a.id: a.name},
              applianceIcons: {for (final a in appliances) a.id: a.icon},
              needsSetupIds: {
                for (final a in appliances)
                  if (needsPanelMapping(a)) a.id,
              },
            ),

            // ── 온습도 ─────────────────────────────────────────────────────
            const SizedBox(height: AppSpace.lg),
            sensorAsync.when(
              data: (reading) => _SensorStrip(reading: reading),
              loading: () => const _SensorStrip(reading: null),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // ── 예비 연결(기기에는 닿을 때만 아래) ──────────────────────────
            if (!serverDown) ...[
              const SizedBox(height: AppSpace.sm),
              connectionDetails,
            ],

            if (const bool.fromEnvironment('SIMPLELAY_ROUTINE_MOCK'))
              TextButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: const Text('다가전 모의'),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => Consumer(builder: (context, ref, _) {
                    final api = ref.watch(rpiApiServiceProvider);
                    if (api == null) {
                      return Scaffold(
                          appBar: AppBar(),
                          body: const Center(
                              child: Text('모의 서버 주소를 먼저 설정하세요.')));
                    }
                    return RoutineRehearsalScreen(
                        key: ObjectKey(api), request: api.routineRequest);
                  }),
                )),
              ),
          ],
        ),
      ),
    );
  }

  /// '이번엔 안 할게요'(10/17까지 '다음에') — 이번만 넘긴다(다시 받지 않기가 아니다). 실패하면 카드를 그대로
  /// 두고 말한다 -- 조용히 지우면 서버에는 카드가 살아 있다.
  static Future<void> _later(
    BuildContext context,
    WidgetRef ref,
    Suggestion suggestion,
  ) async {
    final api = ref.read(rpiApiServiceProvider);
    if (suggestion.source == SuggestionSource.http && api != null) {
      try {
        await api.rejectSuggestion(suggestion.sequenceId, mute: false);
      } on RpiApiException catch (e) {
        if (e.statusCode != 404) {
          if (context.mounted) {
            _snack(context, '고른 것을 본체에 알리지 못했어요. 연결을 봐 주세요.');
          }
          return;
        }
      } catch (_) {
        if (context.mounted) {
          _snack(context, '고른 것을 본체에 알리지 못했어요. 연결을 봐 주세요.');
        }
        return;
      }
    }
    await ref.read(suggestionProvider.notifier).respond(suggestion, false);
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 타일 상태의 근거가 될 서버 판정. 이 폰의 저장분은 준비 상태를 들고 있지 않으므로
  /// 같은 id의 서버 목록 항목을 본다(이름·사진은 덮어쓰지 않는다 — 판정만 읽는다).
  static ApplianceMap? _readinessSource(
      ApplianceMap a, ServerApplianceCatalog catalog) {
    if (a.readinessKnown) return a;
    for (final s in catalog.appliances) {
      if (s.id == a.id) return s;
    }
    for (final s in catalog.customAppliances) {
      if (s.id == a.id) return s;
    }
    return null;
  }
}

/// 홈 구획 제목(카드 제목 단계 20).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.sm),
        child: Semantics(header: true, child: Text(text, style: AppText.title)),
      );
}

/// 홈 '확인이 필요해요'의 안 본 알림 줄 — 이름은 하나, '안 본 알림 N건'(설정 줄·설정 탭 접근성 이름과 같은 말).
///
/// 평가 11·12차(10/18)에 종류 말('자동으로 한 일·루틴 안내 알림 4건, 아직 안 봤어요')을 붙였더니 평가 13차(10/18)에서
/// 분류 나열 말투에 어절 중간에서 끊겼고, 문제가 아닌 알림도 경고처럼 읽혔다. 그래서 종류는 **봐야 할 것이 섞였을 때만**
/// 가장 무거운 것 하나를 짧은 말로 붙인다('안 본 알림 3건, 못 한 일이 있어요'). 자동으로 한 일·루틴 안내뿐이면 건수만.
///
/// 평가 15차(10/18): '안 본 알림 7건, 못 한 일이 있어요'는 한 줄에 두 가지를 말하면서 **무엇을** 못 했는지는
/// 없었다 → 봐야 할 것이 있으면 그 갈래만 한 줄('못 한 일 1건: 공기청정기 바람 중간으로 하기' — 가장 최근 것의
/// 이름, 기록이 아는 말만), 나머지 알림은 따로 '안 본 알림 6건'([CareAttentionLines.rest]). 봐야 할 것이 없으면
/// 중립 한 줄 '안 본 알림 N건'만.
typedef CareAttentionLines = ({String? look, String? rest});

CareAttentionLines careAttentionLines(List<RpiCareEvent> unread) {
  if (unread.isEmpty) return (look: null, rest: null);
  final group = _careLookGroup(unread);
  if (group == null) return (look: null, rest: '안 본 알림 ${unread.length}건');
  final (word, kinds) = group;
  final hits = [for (final e in unread) if (kinds.contains(e.kind)) e]
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  final what = careEventWhat(hits.first);
  // 평가 16차(10/18): '못 한 일 3건: 공기청정기 바람 세기 중'은 끝 '중'이 '진행 중'처럼 읽혔고 기록('바람 중간으로 하기 ·
  // 3번 못 했어요')과 이름·단위가 달랐다 → 기록과 같은 행동 이름, 횟수는 '번'으로 끝 괄호에. 이름이 서로 다른 일이
  // 섞였으면 가장 최근 것의 이름과 '외 N번'(한 이름에 다른 일의 횟수를 붙이지 않는다).
  final String look;
  if (what == null) {
    look = '$word ${hits.length}번';
  } else {
    final same = hits.where((e) => careEventWhat(e) == what).length;
    final others = hits.length - same;
    // 평가 17차(10/18): 끝 괄호 '(3번)'이 혼자 다음 줄로 갔다 → 여러 번이면 '공기청정기 바람 중간으로 하기 · 3번 못
    // 했어요'처럼 횟수와 결과를 문장 끝에 붙인다(기록 칩 '3번 못 했어요'와 같은 말).
    final verb = switch (word) { '못 한 일' => '못 했어요', '멈춘 일' => '멈췄어요', _ => null };
    if (same > 1 && verb != null) {
      look = '$what · $same번 $verb${others > 0 ? ', 다른 일 $others번' : ''}';
    } else {
      look = '$word: $what${same > 1 ? ' $same번' : ''}${others > 0 ? ' 외 $others번' : ''}';
    }
  }
  return (
    look: look,
    // 휴리스틱 평가(10/18): '그 밖에 안 본 알림 4건'(홈)과 '안 본 알림 7건'(설정)이 달라 헷갈렸다 → 홈·설정 같은 수 하나
    // (전체 안 본 수). 위 실패 경고로 따로 보인 것도 이 수에 들어 있다.
    rest: '안 본 알림 ${unread.length}건',
  );
}

/// 홈·접근성에서 쓰는 한 문장(두 줄을 이은 것).
String careAttentionText(List<RpiCareEvent> unread) {
  final l = careAttentionLines(unread);
  return [if (l.look != null) l.look!, if (l.rest != null) l.rest!].join(', ');
}

/// 알림 한 건이 **무엇에 대한** 것인지 — 서버가 적은 목적 문장(행동 이름으로), 없으면 알림 문장의 따옴표 속 이름
/// (본체 요약 '공기청정기 바람 세기 중'도 기록과 같은 행동 이름 '공기청정기 바람 중간으로 하기'로). 둘 다 없으면 null.
String? careEventWhat(RpiCareEvent e) {
  final purpose = e.purpose?.trim() ?? '';
  if (purpose.isNotEmpty) return purposeActionName(purpose);
  final quoted = RegExp(r"'([^']+)'").firstMatch(e.message);
  final label = quoted?.group(1)?.trim();
  return (label == null || label.isEmpty) ? null : summaryActionName(label);
}

/// 안 본 알림 가운데 사람이 봐야 할 것(위험 소리·실패·정지·루틴 멈춤·안부 신호)이 있는가 — 경고색은 이때만.
bool careNeedsLook(List<RpiCareEvent> unread) => _careLookGroup(unread) != null;

/// 봐야 할 갈래 가운데 가장 무거운 것 하나 — (짧은 이름, 그 갈래의 종류들). 없으면 null(자동으로 한 일·루틴 안내·모르는 종류).
(String, Set<String>)? _careLookGroup(List<RpiCareEvent> unread) {
  const order = [
    ('위험 소리', {'danger_sound'}),
    ('못 한 일', {'execution_failed', 'appliance_done_undelivered'}),
    ('멈춘 일', {'emergency_stop'}),
    ('멈춘 루틴', {'routine_stopped'}),
    ('안부 신호', {'quiet_routine'}),
  ];
  final kinds = {for (final e in unread) e.kind};
  for (final g in order) {
    if (kinds.any(g.$2.contains)) return g;
  }
  return null;
}

// ── 지금 우리 집 ─────────────────────────────────────────────────────────────

/// 맨 위 요약 한 장 — 공기 · 다음 예정(큰 시각과 자동 배지).
///
/// 가전 전원은 여기서 말하지 않는다 — 가전 타일 띠('켜져 있어요')가 말한다(평가 11차 10/18: '공기청정기 켜짐'과
/// 타일 '켜져 있어요'가 겹치고 명사형·문장형이 섞였다).
///
/// **아는 것만 말한다.** 공기 등급은 본체가 최근에 읽은 값일 때만(모르면 그 칸을 비운다),
/// 둘 다 모르면 카드 자체가 없다. 공기 '좋음'도 초록으로 칠하지 않는다(초록은 실제 확인 결과 전용).
class _HomeNow extends ConsumerWidget {
  const _HomeNow();

  static const _airWords = {
    'GOOD': '좋음',
    'NORMAL': '보통',
    'BAD': '나쁨',
    'VERY_BAD': '매우 나쁨',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grade = ref.watch(thinqAirProvider).valueOrNull;
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final air = grade == null ? null : _airWords[grade];
    final facts = <Widget>[
      if (air != null)
        _Fact(
          icon: Icons.air,
          text: '공기 $air',
          color: grade == 'BAD' || grade == 'VERY_BAD' ? context.appWarning : null,
        ),
    ];
    if (facts.isEmpty && next == null) return const SizedBox.shrink();

    // 평가 14차(10/18): 옅은 회색 면이 '확인이 필요해요' 카드와 같아 주인공이 약했다 → 면 없이 큰 제목과 큰 글자로
    // 위계를 준다(이 화면의 첫 구역). 간격은 한 단계씩 좁힌다(평가 6차 10/18: 첫 화면에 가전 두 줄이 보이게).
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Container(
        key: const Key('home-now'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text('지금 우리 집',
                    style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(spacing: AppSpace.lg, runSpacing: AppSpace.sm, children: facts),
              ],
              if (next != null) ...[
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.md),
                  Divider(height: 1, color: context.appBorderFaint),
                ],
                const SizedBox(height: AppSpace.md),
                _NextUp(next: next),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: color ?? context.appMuted),
          const SizedBox(width: AppSpace.sm),
          // 핵심 한 줄은 크게(정보 피라미드, 평가 5차 10/18).
          Flexible(
            child: Text(keepWordsTogether(text),
                semanticsLabel: text,
                style: TextStyle(
                    fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      );
}

/// 다음 예정 — 큰 시각(32) · 무엇을 · 언제 · 자동/물어보고 배지.
class _NextUp extends StatelessWidget {
  const _NextUp({required this.next});
  final RoutineNextRun next;

  @override
  Widget build(BuildContext context) {
    final n = next;
    // 큰 시각 바로 옆이라 '매일 22:00'의 시각은 되풀이하지 않는다(평가 6차 10/18) — 큰 시각과 **같을 때만** 뺀다
    // (다르면 시간대가 어긋난 것이라 그대로 둔다, 2차 평가 10/18).
    final repeat = withAmPm(n.when.contains(n.clock) ? n.when.replaceAll(n.clock, '').trim() : n.when);
    final when = [
      if (n.dayLabel.isNotEmpty) n.dayLabel,
      if (repeat.isNotEmpty) repeat,
    ].join(' · ');
    // 루틴 탭 다음 실행 줄과 같은 말(평가 4차 10/18: 여기는 '자동', 루틴 탭은 '자동 실행'이었다).
    // 한 번 건너뛴 회차(2026-10-18)는 본체 말 '오늘은 건너뛰어요' — 중립색(초록·실패 색 아님), '자동으로 해요'는 함께 말하지 않는다.
    final badge = n.quietSkip
        ? StatusBadge(icon: AppIcons.quietHours, label: n.modeText)
        : n.skipped
            ? StatusBadge(key: const Key('home-next-skipped'), icon: AppIcons.skipOnce, label: n.skipText)
        // 평가 14차(10/18): 칩 '자동으로 해요'와 루틴 줄 '자동'·탭 '자동으로 하기'가 섞였다 → 루틴 줄과 같은 짧은 '자동'(칩 아님).
        : n.auto
            ? Semantics(
                label: '자동 루틴, 묻지 않고 해요',
                excludeSemantics: true,
                child: Text('자동',
                    key: const Key('home-next-auto'),
                    style: TextStyle(
                        fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appPrimary)),
              )
            : n.mode == RoutineMode.notify.value || n.modeLabel == RoutineMode.notify.label
                ? StatusBadge(icon: AppIcons.notify, label: n.modeText)
                : const StatusBadge(icon: Icons.front_hand_outlined, label: '물어보고 해요');
    // 오전/오후 표기(평가 7차 10/18) — 루틴 목록의 '매일 오전 7:00'과 같은 꼴. 큰 숫자는 '7:00', 그 위에 작은 '오전'.
    final ampm = ampmClock(n.clock);
    final split = ampm.indexOf(' ');
    final clock = Semantics(
      label: ampm,
      excludeSemantics: true,
      child: Column(
        key: const Key('home-next-clock'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (split > 0)
            Text(ampm.substring(0, split),
                style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appMuted)),
          Text(
            split > 0 ? ampm.substring(split + 1) : ampm,
            style: TextStyle(
              fontSize: AppFont.number,
              fontWeight: FontWeight.w700,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: context.appInk,
            ),
          ),
        ],
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(keepWordsTogether(n.name), semanticsLabel: n.name, style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.xs),
        // 언제와 배지를 한 줄에 — 좁으면 배지가 아래로 내려간다.
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (when.isNotEmpty)
              Text(keepPhrasesTogether(when, wholeParts: MediaQuery.textScalerOf(context).scale(1) <= 1.3),
                  semanticsLabel: when, style: context.appCaption),
            badge,
          ],
        ),
        // '오늘은 건너뛰기' / '되돌리기' — 이 회차 한 번만(본체가 단추 말을 줄 때만, 조용한 시간 회차는 없음).
        if (n.canSkip) ...[
          const SizedBox(height: AppSpace.xs),
          SkipNextControl(next: n),
        ],
      ],
    );
    // 큰 글씨에서는 시각을 위에, 설명을 아래에 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [clock, const SizedBox(height: AppSpace.xs), info],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        clock,
        const SizedBox(width: AppSpace.lg),
        Expanded(child: info),
      ],
    );
  }
}

// ── 실패 경고 · 해야 할 일 · 안 본 알림 ─────────────────────────────────────────

/// 홈 맨 위 **실패 경고**(휴리스틱 평가 10/18 — 실패 경고·일반 알림·설정 남음이 '확인이 필요해요' 한 상자에 같은 무게로
/// 섞였다). 가장 무거운 것 하나와 할 일 단추 하나만 — 있을 때만.
///
/// - 지난 일을 못 했으면(failed) '지난 일을 못 했어요 · 결과 보기', 됐는지 모르면(unconfirmed) '지난 일이 됐는지 몰라요 · 결과 보기'.
///   됐다고 말하지 않는다 — 상태 화면에서 무엇이 확인됐는지 본다.
/// - 안 본 알림에 못 한 일이 있으면 '공기청정기 바람 중간으로 하기 · 3번 못 했어요 · 기록 보기'(못 한 일만 거른 기록으로).
///   위험 소리·멈춘 일 같은 다른 볼 것은 '알림 보기'(보호자 알림함).
class _FailureAlert extends ConsumerWidget {
  const _FailureAlert({required this.execution});

  final ExecutionStatus execution;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCare = ref.watch(careEventsProvider.select((s) => s.unreadEvents));
    final look = careAttentionLines(unreadCare).look;
    final failed = look != null && careLookIsFailure(unreadCare);
    final (String text, Color color, IconData icon, String actionLabel, VoidCallback onAction)? alert =
        switch (execution.phase) {
      ExecutionPhase.failed => ('지난 일을 못 했어요', context.appDanger, Icons.cancel_outlined, '결과 보기',
          () => context.push('/status')),
      ExecutionPhase.unconfirmed => ('지난 일이 됐는지 몰라요', context.appWarning, Icons.help_outline, '결과 보기',
          () => context.push('/status')),
      _ => look == null
          ? null
          : (
              look,
              failed ? context.appDanger : context.appWarning,
              failed ? Icons.cancel_outlined : Icons.error_outline,
              failed ? '기록 보기' : '알림 보기',
              failed
                  ? () {
                      // 못 한 일만 거른 기록으로(보호자 과업 평가 10/18 — 어제 실패를 찾기 쉽게).
                      ref.read(historyFailedOnlyProvider.notifier).state = true;
                      // 보러 간다 = 봤다(사용자 보고 10/19: 기록을 보고 와도 경고가 남았다) — 본체에 적어 이 경고·설정 탭
                      // 배지·키오스크 표시가 함께 사라진다. 새 실패는 다시 뜬다.
                      unawaited(ref.read(careEventsProvider.notifier).markFailuresSeen());
                      context.go('/history');
                    }
                  : () => context.push('/care'),
            ),
    };
    if (alert == null) return const SizedBox.shrink();
    final (text, color, icon, actionLabel, onAction) = alert;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Container(
        key: const Key('home-failure'),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        padding: const EdgeInsets.only(left: AppSpace.md, right: AppSpace.xs),
        // 한 줄 — 무엇을 못 했는지 + 오른쪽 할 일 단추(첫 화면에 가전 두 줄이 남게, 평가 6차 10/18).
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(icon, size: AppSpace.xl, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            // '알림 / 4건'처럼 숫자가 앞 낱말과 갈리지 않게. 말줄임 없이.
            child: Text(keepPhrasesTogether(text),
                semanticsLabel: text,
                style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: color)),
          ),
          TextButton(
            key: const Key('home-failure-action'),
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              foregroundColor: color,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(keepWordsTogether(actionLabel),
                  semanticsLabel: actionLabel,
                  style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
              const Icon(Icons.chevron_right, size: AppSpace.xl),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 안 본 알림 가운데 가장 무거운 볼 것이 '못 한 일'(실행 실패)인가 — 실패 경고의 색·할 일 단추가 갈린다.
bool careLookIsFailure(List<RpiCareEvent> unread) => _careLookGroup(unread)?.$1 == '못 한 일';

/// '해야 할 일'(설정이 남은 가전)과 안 본 알림 한 줄 — 실패 경고 아래, 가전 위.
///
/// 설정 남음은 사람이 할 일이라 제목 '해야 할 일' 아래 그 가전 카드(둘 이상은 한 줄). 안 본 알림은 **설정과 같은 수 하나**
/// ('안 본 알림 7건' — 위 실패 경고로 보인 것도 센다)를 중립색 한 줄로.
class _TodoAndUnread extends ConsumerWidget {
  const _TodoAndUnread({required this.setupCandidates});

  final List<ApplianceMap> setupCandidates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = pendingSetupAppliances(ref, setupCandidates);
    final unreadCare = ref.watch(careEventsProvider.select((s) => s.unreadEvents));
    final rest = careAttentionLines(unreadCare).rest;
    if (pending.isEmpty && rest == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: pending.isEmpty ? AppSpace.sm : AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending.isNotEmpty)
            Container(
              key: const Key('home-todo'),
              // 평가 16차(10/18): 면 없이 왼쪽 굵은 색 선과 글자만(가전 카드와 다른 문법).
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: context.appWarning, width: 4)),
              ),
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.sm, AppSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.checklist_rounded,
                        key: const Key('home-attention-icon'), size: AppSpace.xl, color: context.appWarning),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text('해야 할 일',
                            style: TextStyle(
                                fontSize: AppFont.body, fontWeight: FontWeight.w700, color: context.appWarning)),
                      ),
                    ),
                  ]),
                  // 한 대면 그 가전의 설정 카드를 그대로(연습 자리 확인이면 '실제 자리는 몰라요'까지), 둘 이상은 한 줄.
                  if (pending.length == 1)
                    ApplianceSetupCard(appliance: pending.single, flat: true)
                  else
                    SetupSummaryRow(appliances: pending),
                ],
              ),
            ),
          if (rest != null)
            Padding(
              padding: EdgeInsets.only(top: pending.isNotEmpty ? AppSpace.sm : 0),
              child: _AttentionRow(
                key: const Key('home-unread'),
                // 알림 줄이라 알림 아이콘, 중립색 — 볼 것은 위 실패 경고가 말한다.
                icon: Icons.notifications_none,
                text: rest,
                color: Theme.of(context).colorScheme.onSurface,
                onTap: () => context.push('/care'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    required this.onTap,
  });
  final IconData? icon;
  final String text;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: text,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(children: [
              // 아이콘이 없는 줄도 글자는 같은 세로줄(아이콘 칸 20 + 사이 8).
              if (icon case final i?) Icon(i, size: 20, color: color) else const SizedBox(width: AppSpace.xl),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                // '알림 / 4건'처럼 숫자가 앞 낱말과 갈리지 않게(평가 13차 10/18).
                child: Text(keepPhrasesTogether(text),
                    style: TextStyle(fontSize: AppFont.caption, color: color)),
              ),
              Icon(Icons.chevron_right, color: context.appMuted),
            ]),
          ),
        ),
      );
}

// ── 내 루틴 타일 ─────────────────────────────────────────────────────────────

/// 홈의 루틴 자리(2026-10-18) — **직접 실행하는** 적격 루틴을 2열 타일로 넷까지.
///
/// 시각 루틴은 정해진 때 저절로 돌고 '지금 우리 집'의 다음 예정이 이미 말한다 — 타일로 겹치지 않는다.
/// 자동 순위·즐겨찾기가 아니라 서버가 준 목록 순서다('자주'·'추천' 같은 이유를 붙이지 않는다).
/// 타일을 누르면 승인 카드만 만든다(루틴 탭과 같은 경로) — 가전은 승인 화면에서 허락해야 움직인다.
class _HomeRoutines extends ConsumerStatefulWidget {
  const _HomeRoutines({
    required this.hubConnected,
    required this.hasAppliances,
    required this.applianceNames,
    this.applianceIcons = const {},
    this.needsSetupIds = const {},
  });

  /// 가전 id → 아이콘. 루틴 타일 아이콘을 대상 가전 아이콘으로(평가 3차 10/18).
  final Map<String, IconData> applianceIcons;

  /// 위치(버튼 자리)를 아직 맞추지 않은 가전 — 이 가전을 쓰는 루틴 타일은 설정으로 보낸다.
  final Set<String> needsSetupIds;

  final bool hubConnected;
  final bool hasAppliances;
  final Map<String, String> applianceNames;

  @override
  ConsumerState<_HomeRoutines> createState() => _HomeRoutinesState();
}

class _HomeRoutinesState extends ConsumerState<_HomeRoutines> {
  String? _runningId;
  String? _error;
  String? _errorFor;

  static const _maxTiles = 4;

  Future<void> _run(Routine r) async {
    final id = r.id!;
    if (_runningId != null) return;
    try {
      // 먼저 무엇을 하는지 묻는다(휴리스틱 평가 10/18) — 고르면 루틴 탭과 같은 승인 카드 경로.
      final error = await confirmAndRunRoutine(context, ref, r, onConfirmed: () {
        if (!mounted) return;
        setState(() {
          _runningId = id;
          _error = null;
        });
      });
      if (mounted && error != null) {
        setState(() {
          _error = error;
          _errorFor = id;
        });
      }
    } finally {
      if (mounted) setState(() => _runningId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(routinesProvider);
    return async.when(
      // 불러오는 중에는 자리를 비워 둔다 — '없음'으로 보이지 않게.
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        // 허브 주소가 없거나 허브에 닿지 않으면 위의 허브 안내가 이미 말한다.
        if (e is RoutinesUnavailable || !widget.hubConnected) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxl),
          child: Text('루틴을 불러오지 못했어요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        );
      },
      data: (routines) {
        if (routines.isEmpty) {
          // 0대면 가전 추가가 첫 과업이다 — 루틴 입구를 겹쳐 두지 않는다.
          if (!widget.hasAppliances) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: AppSpace.xxl),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('home-new-routine'),
                onPressed: () => context.push('/routine/edit'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 루틴 만들기'),
              ),
            ),
          );
        }
        bool needsSetup(Routine r) => r.applianceIds.any(widget.needsSetupIds.contains);
        final manual = [
          for (final r in routines)
            if (r.isRunCandidate && r.trigger.kind != RoutineTriggerKind.time) r,
        ];
        if (manual.isEmpty) return const SizedBox.shrink();
        // 준비된 루틴이 먼저, 설정이 필요한 루틴은 뒤.
        final ordered = [
          ...manual.where((r) => !needsSetup(r)),
          ...manual.where(needsSetup),
        ];
        final shown = ordered.take(_maxTiles).toList();
        final more = routines.length > shown.length;
        final busy = _runningId != null;
        final tiles = [
          for (final r in shown)
            _RoutineTile(
              routine: r,
              subtitle: routineSubtitle(r, widget.applianceNames),
              iconOf: widget.applianceIcons,
              running: _runningId == r.id,
              busy: busy,
              needsSetup: needsSetup(r),
              onTap: needsSetup(r)
                  // 설정이 필요한 가전으로 바로 간다(UI 평가 10/17).
                  ? () => context.push('/appliance/detail/'
                      '${r.applianceIds.firstWhere(widget.needsSetupIds.contains, orElse: () => r.applianceIds.first)}')
                  : () => _run(r),
            ),
        ];
        final errorRoutine = shown.where((r) => r.id == _errorFor).firstOrNull;
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxl),
          child: Column(
            key: const Key('home-routines'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 제목과 '루틴 더 보기'는 한 줄에 다 들어갈 때만 나란히 — 큰 글씨에서는 버튼이 다음 줄로 간다
              // (평가 4차 10/18: 200%에서 '내 루/틴'으로 꺾였다).
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                const _SectionTitle('내 루틴'),
                if (more)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: TextButton(
                      key: const Key('home-routines-more'),
                      onPressed: () => context.go('/routines'),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('루틴 더 보기', style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                        Icon(Icons.chevron_right, size: 20, color: context.appMuted),
                      ]),
                    ),
                  ),
              ]),
              // 줄 목록 — 가전 타일(카드)과 다른 모양(평가 5차 10/18).
              for (var i = 0; i < tiles.length; i++) ...[
                tiles[i],
                if (i + 1 < tiles.length) Divider(height: 1, color: context.appBorderFaint),
              ],
              if (errorRoutine != null && _error != null)
                _ErrorLine('${errorRoutine.name}: $_error'),
            ],
          ),
        );
      },
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Text(keepWordsTogether(text),
            style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
      );
}

/// 루틴 한 줄 — 아이콘 · 이름 · 무엇을 · 오른쪽 '지금 하기 >' 표시(설정이 필요하면 같은 꼴의 '설정하기 >').
///
/// 평가 5차(10/18): 가전 타일과 같은 흰 카드 2열이라 가전인지 루틴인지 모양으로 갈리지 않았다 — 루틴은 카드가 아닌
/// 줄 목록으로 둔다. 누르면 승인 카드만 만든다(설정이 필요하면 그 가전으로). 가전은 승인 화면에서 허락해야 움직인다.
class _RoutineTile extends StatelessWidget {
  const _RoutineTile({
    required this.routine,
    required this.subtitle,
    required this.running,
    required this.busy,
    required this.needsSetup,
    required this.onTap,
    this.iconOf = const {},
  });

  final Routine routine;
  final String subtitle;
  final Map<String, IconData> iconOf;
  final bool running;
  final bool busy;
  final bool needsSetup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = routine;
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final Widget trailing = running
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        // 설정이 남았으면 같은 꼴의 '설정하기 >' — 무엇이 남았는지는 '확인이 필요해요' 한 곳에서(평가 3차 10/18).
        // 평가 11차(10/18): 글자 단추와 회색 '설정 필요' 칩이 섞여 있었다 — 루틴 탭 줄과 같은 글자 단추.
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Text(keepWordsTogether(needsSetup ? kSetupActionLabel : '지금 하기'),
                style: TextStyle(
                    fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appInk)),
            Icon(Icons.chevron_right, size: 20, color: context.appMuted),
          ]);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(keepWordsTogether(r.name),
            style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
        // 낱말·묶음 중간에서 꺾이지 않게("1단 / 계" 2026-10-14, "LG / 가전 설정" 평가 4차 10/18).
        Text(keepPhrasesTogether(subtitle, wholeParts: !big),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: context.appCaption),
      ],
    );
    return Semantics(
      // 화면 글자는 이름뿐이어도 읽을 때는 무엇을 하는지 말한다.
      label: needsSetup ? '${r.name} 가전 설정하기' : '${r.name} 실행하기',
      container: true,
      button: true,
      enabled: needsSetup || !busy,
      excludeSemantics: true,
      child: InkWell(
        key: Key('home-routine-tile-${r.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: needsSetup || !busy ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm, horizontal: AppSpace.xs),
            child: big
                // 큰 글씨: 오른쪽 표시를 이름 아래로 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      _RoutineDot(routine: r, iconOf: iconOf, muted: needsSetup),
                      const SizedBox(width: AppSpace.md),
                      Expanded(child: info),
                    ]),
                    const SizedBox(height: AppSpace.xs),
                    trailing,
                  ])
                : Row(children: [
                    _RoutineDot(routine: r, iconOf: iconOf, muted: needsSetup),
                    const SizedBox(width: AppSpace.md),
                    Expanded(child: info),
                    const SizedBox(width: AppSpace.sm),
                    trailing,
                  ]),
          ),
        ),
      ),
    );
  }
}

/// 루틴 줄 왼쪽의 둥근 아이콘 자리(대상 가전 아이콘). 강조색은 쓰지 않는다 — 주 행동 색이 아니다.
class _RoutineDot extends StatelessWidget {
  const _RoutineDot({required this.routine, required this.iconOf, required this.muted});
  final Routine routine;
  final Map<String, IconData> iconOf;
  final bool muted;

  @override
  Widget build(BuildContext context) => Container(
        width: AppSpace.xxxl + AppSpace.sm,
        height: AppSpace.xxxl + AppSpace.sm,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: context.appOverlayFaint, shape: BoxShape.circle),
        child: RoutineIcon(routine: routine, iconOf: iconOf, color: muted ? context.appMuted : context.appInk),
      );
}

// ── 머리 ──────────────────────────────────────────────────────────────────

/// 제목 "우리 집"과 허브 연결 칩. 칩은 색만이 아니라 글자로 말한다.
class _Header extends StatelessWidget {
  const _Header({
    required this.rpiState,
    required this.backupOnly,
    required this.onVoice,
  });

  final RpiConnectionState rpiState;

  /// 서버에는 닿지 않지만 예비 연결(BLE)은 살아 있다.
  final bool backupOnly;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final (String text, Color dot) = switch (rpiState) {
      // 정상은 색을 쓰지 않는다(성공 중립 규칙) — 갈색은 주행동 색이라 정상인지 경고인지 안 읽혔다(UI 평가 10/17).
      // 상태 색 표(출시 검토 10/18, 본체와 같게): 연결됨 초록 · 끊김 노랑 · 못 씀 빨강. 라이트의 성공 중립색은 검은 점이었다.
      RpiConnectionState.connected => ('본체와 연결됐어요', context.appConfirmed),
      RpiConnectionState.keyRequired => ('연결 비밀번호가 필요해요', context.appWarning),
      RpiConnectionState.checking ||
      RpiConnectionState.unconfigured =>
        ('본체를 찾고 있어요', context.appMuted),
      RpiConnectionState.unreachable =>
        (backupOnly ? '블루투스로만 연결돼요' : '본체와 연결이 끊겼어요', context.appWarning),
    };
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const Key('hub-status-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpace.sm),
          Flexible(child: Text(keepWordsTogether(text), semanticsLabel: text, style: const TextStyle(fontSize: AppFont.caption))),
        ],
      ),
    );
    // 말로 하는 길 -- 누르기 어려운 사용자에게 길이 하나뿐이면 안 된다.
    // 휴리스틱 평가(10/18): 마이크 아이콘만 있어 무엇인지 몰랐다 → 짧은 글자 '말로 하기'를 함께.
    // 아이콘 아래 작은 글자(탭 막대와 같은 꼴) — 옆으로 붙이면 칩 문구가 두 줄로 꺾였다.
    final voice = Semantics(
      label: '말로 하기',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('home-voice'),
        onTap: onVoice,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mic_none_rounded, color: context.appPrimary),
              Text('말로 하기',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appPrimary, height: 1.1)),
            ]),
          ),
        ),
      ),
    );
    // 글씨를 키웠거나(120% 넘음) 칩 문구가 한 줄에 다 들어가지 않으면 칩을 제목 아래 줄로 내린다 — 한 줄에 두면 제목과
    // 칩이 서로 폭을 뺏어 "우리 / 집"·"본체와 / 연결됐어요"처럼 꺾인다('말로 하기' 글자가 붙은 뒤, 휴리스틱 평가 10/18).
    Widget stacked() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('우리 집', style: AppText.heading)),
              voice,
            ]),
            const SizedBox(height: AppSpace.sm),
            chip,
          ],
        );
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler.scale(1) > 1.2) return stacked();
    return LayoutBuilder(builder: (context, c) {
      double widthOf(String t, TextStyle s) =>
          (TextPainter(text: TextSpan(text: t, style: s), textDirection: TextDirection.ltr, textScaler: scaler)..layout())
              .width;
      // 제목 + 간격 + 칩(점 8 · 사이 8 · 좌우 여백 8×2 · 테두리) + 간격 + 말로 하기(글자 + 좌우 여백).
      final need = widthOf('우리 집', AppText.heading) +
          AppSpace.sm +
          widthOf(text, const TextStyle(fontSize: AppFont.caption)) +
          AppSpace.sm * 2 + AppSpace.sm * 2 + 2 +
          AppSpace.xs +
          widthOf('말로 하기', const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)) +
          AppSpace.sm;
      if (need > c.maxWidth) return stacked();
      // 제목은 제 폭만 쓰고 남는 자리를 칩에 준다.
      return Row(
        children: [
          Text('우리 집', style: AppText.heading),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: chip),
          ),
          const SizedBox(width: AppSpace.xs),
          voice,
        ],
      );
    });
  }
}

// ── 지금 할 일(제안 카드) ────────────────────────────────────────────────

/// 제안 한 장 — 무엇을(가전·이름), 왜 지금(이유 한 줄), 주 버튼 '지금 하기' 하나.
///
/// '지금 하기'는 **바로 누르지 않는다.** 누를 순서와 대상 가전을 보여 주는
/// 확인 화면을 연다 -- 허락은 거기서 한 번이고, 내용이 바뀌면(409)
/// 그 화면이 다시 확인하게 한다. '이번엔 안 할게요'는 글자 버튼(취소 위계).
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.suggestion,
    required this.appliance,
    required this.onRun,
    required this.onLater,
  });

  final Suggestion suggestion;
  final ApplianceMap? appliance;
  final VoidCallback onRun;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    final why = suggestion.whyNow;
    return Container(
      key: const Key('home-suggestion'),
      padding: const EdgeInsets.all(AppSpace.xl),
      decoration: BoxDecoration(
        color: context.appPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.appPrimary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(a?.icon ?? Icons.lightbulb_outline,
                  size: 20, color: context.appPrimary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  a == null ? '지금 할 일' : '지금 할 일 · ${a.displayName}',
                  style: context.appCaption,
                ),
              ),
              if (suggestion.isDemo) const DemoBadge(),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            suggestion.title,
            style: const TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700),
          ),
          if (why.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(why, style: context.appCaption),
          ],
          const SizedBox(height: AppSpace.lg),
          // 화면 글자는 짧게, 읽는 이름에는 대상을(2026-10-14, 발견 5).
          Semantics(
            label: '${suggestion.title} 지금 하기',
            container: true,
            button: true,
            excludeSemantics: true,
            child: FilledButton(
              onPressed: onRun,
              child: const Text('지금 하기'),
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Center(
            child: Semantics(
              label: '${suggestion.title} 다음에',
              container: true,
              button: true,
              excludeSemantics: true,
              child: TextButton(
                onPressed: onLater,
                child: Text('이번엔 안 할게요', style: TextStyle(color: context.appMuted)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 가전 카드 2열 ─────────────────────────────────────────────────────────

class _ApplianceGrid extends StatelessWidget {
  const _ApplianceGrid({
    required this.appliances,
    required this.statusOf,
    required this.verifyNoteOf,
    required this.onOpen,
    required this.onAdd,
  });

  final List<ApplianceMap> appliances;

  /// 상태 줄과 별개의 '확인 주행' 보조 줄([verifyPassTileNote]). 없으면 null.
  final String? Function(ApplianceMap) verifyNoteOf;

  /// 타일 상태(`models/display_status.dart`의 순수 함수).
  final TileStatus Function(ApplianceMap) statusOf;
  final void Function(ApplianceMap) onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final names = distinctTileNames(appliances);
    final ordered = homeApplianceOrder(appliances);
    Widget card(ApplianceMap a) => _ApplianceCard(
          appliance: a,
          name: names[a.id] ?? a.name,
          status: statusOf(a),
          verifyNote: verifyNoteOf(a),
          onTap: () => onOpen(a),
        );
    // 연습 가전은 따로 '연습해 보기' 구역(결선 모의 평가 10/18 — 실제 '세탁기'(누름 장치용)와 'LG 세탁기'(연습)가 나란히 있어
    // 헷갈렸다). 이름 데이터는 그대로 두고 자리만 나눈다. '가전 추가'는 실제 가전 구역 끝.
    final practice = [for (final a in ordered) if (isPracticeAppliance(a)) card(a)];
    final real = <Widget>[
      for (final a in ordered) if (!isPracticeAppliance(a)) card(a),
      _AddCard(onTap: onAdd),
    ];
    if (practice.isEmpty) return _grid(context, real);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grid(context, real),
        const SizedBox(height: AppSpace.xl),
        const _SectionTitle('연습해 보기', key: Key('home-practice-section')),
        _grid(context, practice),
      ],
    );
  }

  /// 칸 묶음 하나 — 보통 글씨는 두 칸씩, 큰 글씨는 한 칸씩.
  Widget _grid(BuildContext context, List<Widget> cards) {
    // 큰 글씨(120% 넘음)에서는 한 칸씩. 두 칸에 두면 가전 이름(20)이 한 글자씩 꺾인다(평가 5차 10/18: 130%에서 '전자레인|지').
    if (MediaQuery.textScalerOf(context).scale(1) > 1.2) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i + 1 < cards.length ? AppSpace.md : 0),
              child: cards[i],
            ),
        ],
      );
    }
    // 두 칸씩 줄을 세운다. GridView의 고정 높이는 큰 글씨에서 글자를 자른다 --
    // 줄마다 높이를 내용에 맞춘다.
    return Column(
      children: [
        for (var i = 0; i < cards.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: i + 2 < cards.length ? AppSpace.md : 0),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[i]),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: i + 1 < cards.length
                        ? cards[i + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

}

/// 가전 타일 — 아이콘 + 이름만(사용자 결정 2026-10-19: 아래 상태 글자 띠가 너무 복잡했다. 키오스크와 같은 규칙).
///
/// - 밝기 = 켜짐·작동 중(사용자 결정 10/19, 두 번째): 밝게(본문 글자색 아이콘·이름)는 [tileLit]일 때만, 그 밖은 흐리게
///   ([AppColorsX.appTileDim]). 카드 면은 바꾸지 않는다. LG 가전은 본체가 **읽은** 켜짐만 밝다.
/// - 문제가 있을 때만 오른쪽 위 작은 표시 하나([TileStatus.issue] 또는 자리 확인 보조 줄) — 쓸 수 없음 '!',
///   확인 전·모름 '?', 설정 남음 톱니. 누르면 말풍선으로 한두 문장, 화면 읽기는 그 문장을 그대로 읽는다.
/// - 버튼 조작 중은 잉크색 테두리 + 진행 막대(글자 없이 — 화면 읽기 이름이 말한다).
/// 다른 곳의 상태 안내(홈 '해야 할 일' 등)는 그대로다.
class _ApplianceCard extends ConsumerWidget {
  const _ApplianceCard({
    required this.appliance,
    required this.name,
    required this.status,
    required this.onTap,
    this.verifyNote,
  });

  final ApplianceMap appliance;

  /// 타일에 적을 이름([distinctTileNames]) — 같은 이름이 둘이면 " (2)"가 붙는다.
  final String name;

  /// '확인 주행' 보조 줄. 상태가 평소일 때 설정 톱니 표시의 문장이 된다.
  final String? verifyNote;

  /// 타일 상태. "돌아가는 중"은 없다 — 버튼 조작 진행·준비 여부까지만.
  final TileStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = appliance;
    final s = status;
    final active = s.tone == TileTone.active;
    final run = ref.watch(executionStatusProvider);
    final total = run.totalSteps ?? run.steps.length;
    final done = run.completedSteps;
    // 자리 확인을 실제로 마치지 못한 가전(평가 10차 판정 그대로) — 평소 상태일 때만 설정 톱니로. 실행을 막지 않는다.
    final note = verifyNote;
    final issue = s.issue ?? (s.tone == TileTone.ready && note != null ? TileIssue(TileMark.setup, note) : null);
    final practice = isPracticeAppliance(a);
    // 연습 가전 화면 이름은 '연습 세탁기'(접근성 감사 10/18 — 실제 '세탁기'와 헷갈렸다, 본체와 같은 규칙).
    final shownName = practiceDisplayName(name);
    // 밝기 = 켜짐·작동 중(10/19, 두 번째) — 아이콘·이름 같은 색. 강조색(골드)은 쓰지 않는다(주 행동 전용).
    final fg = tileLit(s) ? context.appInk : context.appTileDim;
    // 문제가 아닌 상태 말 — 화면 읽기 이름에만(화면 글자는 없다). 밝기(색)만으로 말하지 않는다(10/19, 두 번째):
    // 쉬는 누름 장치 가전은 '작동 중 아님' — 허브가 지금 누르고 있지 않다는 뜻까지만(가전이 꺼졌다고 단정하지 않는다).
    // LG 가전 전원을 모르면 넣지 않는다 — '?' 표시 문장이 말한다.
    final word = switch (s.tone) {
      TileTone.on || TileTone.off || TileTone.active => s.text,
      _ when !a.isThinq => '작동 중 아님',
      _ => null,
    };
    final card = Semantics(
      button: true,
      // excludeSemantics라 아래 글자가 따로 읽히지 않는다 — 문제 문장은 오른쪽 위 표시가 따로 읽는다.
      label: [
        if ((a.location ?? '').isNotEmpty) '${a.location} $shownName' else shownName,
        // 연습 가전에는 'LG 가전'을 쓰지 않는다(출시 검토 10/18 — 실제 LG 가전과 헷갈렸다).
        if (a.isThinq && !practice) 'LG 가전',
        if (practice) '연습',
        if (word != null && word.isNotEmpty) word,
      ].join(', '),
      excludeSemantics: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        // 버튼 조작 중일 때만 테두리. 강조색(갈색)은 주 행동에만 — 잉크색 테두리로.
        shape: active
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: context.appInk, width: 2))
            : null,
        child: InkWell(
          key: Key('appliance-card-${a.id}'),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 가전 그림 + 오른쪽 위 '연습' 표지 — 문제 표시가 있으면 그 왼쪽(겹치지 않게 자리를 비운다).
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          key: Key('appliance-icon-${a.id}'),
                          width: AppSpace.xxxl + AppSpace.sm,
                          height: AppSpace.xxxl + AppSpace.sm,
                          alignment: Alignment.centerLeft,
                          child: Icon(a.icon, size: 28, color: fg),
                        ),
                        // 남는 폭은 배지 칸 하나가 가진다(Spacer와 나누면 배지가 반으로 줄었다).
                        Expanded(
                          child: practice
                              ? Align(
                                  alignment: Alignment.topRight,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: DemoBadge(key: Key('appliance-practice-${a.id}')),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (issue != null) const SizedBox(width: _TileMarkButton.hit - AppSpace.sm),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      shownName,
                      style: TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700, color: fg),
                    ),
                    if ((a.location ?? '').isNotEmpty)
                      Text(a.location!,
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                    // 'LG 가전'은 테두리 칩이 아니라 이름 아래 작은 글자(평가 14차 10/18: 반복 장식).
                    if (a.isThinq && !practice)
                      Text('LG 가전',
                          key: Key('appliance-lg-${a.id}'),
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                  ],
                ),
              ),
              if (s.progress)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.md),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      key: Key('appliance-progress-${a.id}'),
                      minHeight: 5,
                      value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (issue == null) return KeyedSubtree(key: Key('appliance-tile-${a.id}'), child: card);
    return Stack(key: Key('appliance-tile-${a.id}'), fit: StackFit.passthrough, children: [
      card,
      // 카드 안 오른쪽 위 — 보이는 원은 작게, 누르는 자리는 48dp.
      Positioned(
        top: AppSpace.xs,
        right: AppSpace.xs,
        child: _TileMarkButton(key: Key('appliance-mark-${a.id}'), issue: issue),
      ),
    ]);
  }
}

/// 타일 오른쪽 위 문제 표시(사용자 결정 10/19, 키오스크 `KioskTileMarkButton`과 같은 모양·문장). 누르면 말풍선
/// (몇 초 뒤 또는 바깥을 누르면 닫힘). 화면 읽기는 문장을 그대로 읽는다(색·모양만으로 말하지 않는다).
class _TileMarkButton extends StatefulWidget {
  const _TileMarkButton({super.key, required this.issue});

  final TileIssue issue;

  /// 누르는 자리 한 변(48dp).
  static const double hit = 48;

  @override
  State<_TileMarkButton> createState() => _TileMarkButtonState();
}

class _TileMarkButtonState extends State<_TileMarkButton> {
  final _tip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final mark = widget.issue.mark;
    final unusable = mark == TileMark.unusable;
    final icon = switch (mark) {
      TileMark.unusable => Icons.priority_high_rounded,
      TileMark.unknown => Icons.question_mark_rounded,
      TileMark.setup => Icons.settings_rounded,
    };
    return Semantics(
      button: true,
      label: widget.issue.text,
      onTap: () => _tip.currentState?.ensureTooltipVisible(),
      excludeSemantics: true,
      child: Tooltip(
        key: _tip,
        message: widget.issue.text,
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 4),
        excludeFromSemantics: true,
        textStyle: TextStyle(fontSize: AppFont.caption, color: context.appBackground, height: 1.3),
        decoration: BoxDecoration(color: context.appOnSurfaceSoft, borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        child: SizedBox.square(
          dimension: _TileMarkButton.hit,
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: unusable ? context.appWarning : Colors.transparent,
                border: unusable ? null : Border.all(color: context.appMuted, width: 1.5),
              ),
              child: Icon(icon, size: 16, color: unusable ? context.appOnAccent : context.appMuted),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '가전 추가',
        excludeSemantics: true,
        child: InkWell(
          key: const Key('appliance-add-card'),
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 112),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.appBorderSubtle),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 28, color: context.appMuted),
                const SizedBox(height: AppSpace.xs),
                Text('가전 추가',
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
              ],
            ),
          ),
        ),
      );
}

/// 가전이 0대인 화면에서 **서버 목록 사정**을 한 줄로. 없으면 null.
///
/// 조회 실패와 '서버에 정말 없음'을 같은 빈 화면으로 두지 않는다.
String? _serverCatalogNote(ServerApplianceCatalog catalog) =>
    switch (catalog.status) {
      ServerCatalogStatus.loading => '본체의 가전 목록을 불러오는 중이에요.',
      ServerCatalogStatus.failed => '본체의 가전 목록을 못 불러왔어요. 연결을 봐 주세요.',
      ServerCatalogStatus.loaded || ServerCatalogStatus.unconfigured => null,
    };

/// 설치한 가전이 0대인 홈. **고장이 아니라 시작점**이다 -- 경고색도 오류
/// 문구도 쓰지 않고, 다음에 할 일 하나만 놓는다.
class _NoApplianceStage extends StatelessWidget {
  const _NoApplianceStage({required this.onAdd, this.note});

  final VoidCallback onAdd;
  final String? note;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('아직 등록한 가전이 없어요', style: AppText.title),
          const SizedBox(height: AppSpace.sm),
          Text(
            '조작부 사진을 찍고 버튼 자리를 알려 주면\n여기서 가전을 쓸 수 있어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          if (note case final note?) ...[
            const SizedBox(height: AppSpace.sm),
            Text(note, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ],
          const SizedBox(height: AppSpace.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('가전 추가'),
          ),
        ],
      );
}

// ── 연결 상세 (접힘) ──────────────────────────────────────────────────────

/// 서버·BLE 사정을 한 줄로 접어 둔다.
///
/// **문제가 있으면 펼친 채로 연다.** 접어두는 것은 "지금은 신경 쓰지 않아도
/// 된다"는 뜻인데, 연결이 끊긴 상태에서 그러면 복구 동선이 화면에서
/// 사라진다 -- 가장 도움이 필요한 순간에.
class _ConnectionDetails extends StatefulWidget {
  const _ConnectionDetails({
    required this.rpiState,
    required this.bleConnected,
  });

  final RpiConnectionState rpiState;
  final bool bleConnected;

  @override
  State<_ConnectionDetails> createState() => _ConnectionDetailsState();
}

class _ConnectionDetailsState extends State<_ConnectionDetails> {
  bool _open = false;

  /// 닿지 않는다고 **확인된** 경우만. 확인 중(checking·unconfigured)은 아니다.
  bool get _serverDown => widget.rpiState == RpiConnectionState.unreachable;

  /// 허브에 닿으면 예비 연결이 꺼져도 말하지 않는다(2026-10-14 UX) — 조작은 되고,
  /// 사용자가 그걸로 할 판단이 없다. 허브 연결에 문제가 있을 때만 줄을 둔다.
  bool get _hasProblem => _serverDown;

  @override
  Widget build(BuildContext context) {
    // 문제가 없으면 이 줄 자체를 두지 않는다. 잘 되고 있는 것을 알리는
    // 줄은 화면을 관리 도구로 되돌릴 뿐, 사용자가 그걸로 할 판단이 없다.
    if (!_hasProblem) return const SizedBox.shrink();

    // 둘 다 끊긴 것과 예비 연결로 버티는 것은 문장을 나눈다 -- 조작은 되는데
    // "연결 설정이 필요해요"라고만 하면 무엇이 안 되는지 알 수 없다.
    final (String label, Color color, IconData icon) = widget.bleConnected
            ? ('알림과 기록이 멈췄어요', context.appWarning,
                Icons.wifi_tethering_error)
            : ('연결 설정이 필요해요', context.appDanger,
                Icons.wifi_tethering_error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              // 고령 사용자 기준 최소 터치 대상을 줄 전체로 준다.
              padding: const EdgeInsets.symmetric(vertical: AppSpace.lg, horizontal: AppSpace.xs),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      // 기술 용어를 여기 쓰지 않는다. `RPi 서버`·주소 입력·
                      // 재시도는 눌렀을 때만 나온다.
                      keepWordsTogether(label),
                      style: TextStyle(
                        fontSize: AppFont.caption,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  Text(
                    _open ? '접기' : '확인하기',
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: color),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpace.xs),
          // 닿는 기기를 "연결됐어요" 카드로 다시 말하지 않는다.
          if (_serverDown) _RpiStatusCard(state: widget.rpiState),
          // 예비 연결은 **꺼져 있을 때만** 말한다.
          if (!widget.bleConnected) ...[
            if (_serverDown) const SizedBox(height: AppSpace.md),
            _BleStatusCard(connected: widget.bleConnected),
          ],
        ],
      ],
    );
  }
}

// ── 온습도 스트립 ──────────────────────────────────────────────────────────

class _SensorStrip extends StatelessWidget {
  const _SensorStrip({required this.reading});
  final SensorReading? reading;

  @override
  Widget build(BuildContext context) {
    if (reading?.mocked != false) return const SizedBox.shrink();
    final temp = reading?.temperature;
    final hum = reading?.humidity;
    if (temp == null && hum == null) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: reading != null ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (temp != null) ...[
            Icon(Icons.thermostat_outlined, size: 14, color: context.appMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              '${temp.toStringAsFixed(1)}°C',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
          if (temp != null && hum != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
              child: Text('·', style: TextStyle(color: context.appMuted)),
            ),
          if (hum != null) ...[
            Icon(Icons.water_drop_outlined, size: 14, color: context.appMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              '${hum.toStringAsFixed(0)}%',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ── DND 활성 배너 ─────────────────────────────────────────────────────────

class _DndBanner extends StatelessWidget {
  const _DndBanner({required this.until, required this.onClear});
  final DateTime until;
  final VoidCallback onClear;

  String get _remaining {
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return '끝났어요';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 남음' : '$h시간 남음';
    }
    return '${diff.inMinutes + 1}분 남음';
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(AppIcons.pauseActive, color: context.appWarning, size: 18),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                // 끝나는 시각을 함께 적는다(2026-10-14 마감 확인 A5) — 남은 시간만으로는 '언제까지'를 셈해야 한다.
                '잠시 쉬는 중. ${pauseEndClock(until)}까지, $_remaining',
                style: TextStyle(color: context.appWarning, fontSize: AppFont.caption),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: context.appWarning,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                minimumSize: const Size(48, 48),
              ),
              child: const Text('그만 쉬기', style: TextStyle(fontSize: AppFont.caption)),
            ),
          ],
        ),
      );
}

// ── RPi 연결 상태 카드 ────────────────────────────────────────────────────

class _RpiStatusCard extends ConsumerWidget {
  const _RpiStatusCard({required this.state});
  final RpiConnectionState state;

  // simplelay.local(mDNS)이 안 풀리는 Android 폰을 위한 최후 동선 —
  // IP만 쳐도 normalizeRpiUrl이 http://·:8000을 채워서 저장한다.
  Future<void> _promptForAddress(BuildContext context, WidgetRef ref) async {
    final controller =
        TextEditingController(text: ref.read(rpiUrlProvider) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('본체 주소'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '예: 192.168.0.10',
            helperText: '설치하는 분용이에요. 공유기 관리 화면에서 본체 주소를 찾아 주세요.',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    // save가 정규화 + 저장하고, rpiUrlProvider listen이 연결 확인을 트리거한다
    await ref.read(rpiUrlProvider.notifier).save(result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (Color color, IconData icon, String title, String subtitle) =
        switch (state) {
      // 확인한 것은 /ping 응답뿐이다. 추론 계층이 켜졌는지, 가전이 물려
      // 있는지는 이 신호로 알 수 없다 -- 확인한 만큼만 말한다.
      // (온디바이스 추론 경계는 docs/inference-boundary.md)
      RpiConnectionState.keyRequired => (
          context.appWarning, Icons.key, '연결 비밀번호가 필요해요', '설정에서 연결 비밀번호를 넣어 주세요.'
        ),
      RpiConnectionState.connected => (
          context.appSuccess,
          Icons.wifi,
          '본체와 연결됐어요',
          '말이나 버튼으로 가전을 쓸 수 있어요',
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          Icons.sync,
          '본체 찾는 중…',
          '잠시만 기다려 주세요',
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
          Icons.wifi_off,
          '본체와 연결이 끊겼어요',
          '폰과 본체가 같은 Wi-Fi인지 봐 주세요',
        ),
      RpiConnectionState.unconfigured => (
          context.appMuted,
          Icons.wifi_off,
          '본체 주소를 넣어 주세요',
          '설치하는 분이 설정에서 넣어 주세요',
        ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _StatusCardBody(
          icon: icon,
          color: color,
          title: title,
          subtitle: subtitle,
          actions: [
            if (state == RpiConnectionState.unreachable ||
                state == RpiConnectionState.unconfigured) ...[
              TextButton(
                onPressed: () => _promptForAddress(context, ref),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('주소 입력', style: TextStyle(fontSize: AppFont.caption)),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(rpiConnectionProvider.notifier).check(),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('다시 찾기', style: TextStyle(fontSize: AppFont.caption)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── BLE 연결 상태 카드 (미연결 시만 표시) ─────────────────────────────────

class _BleStatusCard extends StatelessWidget {
  const _BleStatusCard({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: context.appSurfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _StatusCardBody(
            icon: Icons.bluetooth_disabled,
            color: context.appMuted,
            iconBackground: Theme.of(context).colorScheme.surfaceContainerHigh,
            title: '블루투스 연결이 꺼져 있어요',
            subtitle: '켜 두면 Wi-Fi가 끊겨도 가전을 쓸 수 있어요.',
            actions: [
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('연결', style: TextStyle(fontSize: AppFont.caption)),
                ),
              ),
            ],
          ),
        ),
      );
}

/// 상태 카드의 공통 본문 — 아이콘 · 제목/설명 · 동작 버튼.
///
/// **큰 글씨에서 가로 배치가 무너진다.** 아이콘·텍스트·버튼을 한 줄에 두면 200%
/// 확대에서 버튼들이 폭을 다 가져가고 Expanded 텍스트가 한 글자씩 세로로 쪼개졌다
/// ("RPi 서버 미설정"이 여섯 줄이 됐다). 오버플로가 아니라 **압축**이라 레이아웃
/// 테스트가 잡지 못했고, 실제 렌더 이미지를 보고서야 드러났다.
///
/// 그래서 확대 배율이 커지면 버튼을 아래로 내린다. 보통 크기에서는 지금처럼 한 줄로
/// 둔다 -- 늘 세로로 쌓으면 평소 화면이 불필요하게 길어진다.
class _StatusCardBody extends StatelessWidget {
  const _StatusCardBody({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.actions,
    this.iconBackground,
  });

  final IconData icon;
  final Color color;
  final Color? iconBackground;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // 1.0을 넣으면 유효 배율이 그대로 나온다. 배율이 커지면 접는다.
    // 버튼이 둘이면 보통 크기에서도 접는다 -- 나란히 두면 설명이 어중간하게
    // 접혀서("서버 주 / 소를 입력하세요") 읽는 리듬이 끊긴다.
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) > 1.3 || actions.length > 1;

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: iconBackground ?? color.withValues(alpha: 0.15),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: AppSpace.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpace.xs),
              Text(subtitle, style: context.appCaption),
            ],
          ),
        ),
        if (!stacked) ...actions,
      ],
    );

    if (!stacked || actions.isEmpty) return head;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head,
        const SizedBox(height: AppSpace.xs),
        Wrap(spacing: AppSpace.xs, runSpacing: AppSpace.xs, children: actions),
      ],
    );
  }
}


/// 홈 가전 칸 순서 — 바로 쓸 수 있는 가전이 앞, 설정·연결이 남은 가전이 뒤(평가 17차 10/18: 본체 화면 가전 줄과 같은
/// 규칙). 같은 무리 안에서는 등록 순서. 본체 화면의 '확인 필요·동작 중' 앞당김은 홈 칸 띠가 말하므로 두지 않는다.
List<ApplianceMap> homeApplianceOrder(List<ApplianceMap> appliances) {
  bool later(ApplianceMap a) =>
      needsPanelMapping(a) || a.readiness == 'needs_setup' || a.readiness == 'disconnected';
  return [
    for (final a in appliances) if (!later(a)) a,
    for (final a in appliances) if (later(a)) a,
  ];
}
