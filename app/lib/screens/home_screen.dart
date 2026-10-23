import 'dart:async';

import 'package:routine_rehearsal/routine_rehearsal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/care_attention.dart';
export '../models/care_attention.dart';
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
import 'history_screen.dart' show historyAckPendingProvider, historyFailedOnlyProvider;
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
import '../widgets/settings_action.dart';
import '../models/execution_status.dart';
import '../theme/app_tokens.dart';

// 사진 패널의 테스트 이미지 구멍은 사진을 그리는 위젯 쪽에 있다. 예전 경로
// (home_screen.dart)로 쓰던 테스트가 그대로 쓰도록 다시 내보낸다.
export '../widgets/panel_photo_view.dart' show applianceImageOverride;



part 'home/overview.dart';
part 'home/attention.dart';
part 'home/routines.dart';
part 'home/header.dart';
part 'home/suggestion.dart';
part 'home/appliance_grid.dart';
part 'home/appliance_tiles.dart';
part 'home/connectivity.dart';
part 'home/environment.dart';
part 'home/appliances_screen.dart';
part 'home/featured_action.dart';

/// 과업 우선 홈(10/23). 중요한 차단·제안 → 저장한 동작 → 가전 → 환경·예약.
/// 제안이 있으면 제안만 강조하고, 없으면 첫 실행 가능 저장 동작을 강조한다.
///
/// 가전 카드를 눌러도 **실행하지 않는다.** 상세만 열리고, 누르는 일은 늘
/// 확인을 한 번 더 거친다. 루틴 타일도 승인 카드만 만든다.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, this.appliancesOnly = false});
  final bool appliancesOnly;

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
      appBar: appliancesOnly ? AppBar(title: Text('가전', style: AppText.heading), actions: const [SettingsAction()]) : null,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxxl),
          children: [
            if (!appliancesOnly) _Header(
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

            // ── 방해 금지 배너 ─────────────────────────────────────────────
            if (dndActive) ...[
              _DndBanner(
                until: dndUntil,
                carried: ref.watch(dndScopeProvider) == 'suggestions_only',
                onClear: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final bool? persisted;
                  try {
                    persisted = await ref.read(dndProvider.notifier).clear();
                  } catch (_) {
                    // 보내지 못했다 — 쉬기는 그대로다(검토 10/19: 예외가 새어 아무 말이 없었다).
                    messenger.showSnackBar(const SnackBar(content: Text(kDndClearNotSentNotice)));
                    return;
                  }
                  if (persisted == false) {
                    messenger.showSnackBar(const SnackBar(content: Text(kSettingNotSavedNotice)));
                  }
                },
              ),
              const SizedBox(height: AppSpace.lg),
            ],

            // ── 실패 경고(있을 때만, 맨 위 따로 — 휴리스틱 평가 10/18) ─────────────────
            _FailureAlert(execution: execution),

            // ── 지금 우리 집 ─────────────────────────────────────────────

            // ── ① 지금 할 일 ──────────────────────────────────────────────
            // 빈 제안 문장("지금 확인할 제안이 없어요")은 두지 않는다(2026-10-13).
            if (!appliancesOnly && suggestion != null) ...[
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

            // ── ④ 내 루틴 타일 ─────────────────────────────────────────────
            if (!appliancesOnly) _HomeRoutines(
              featureFirst: suggestion == null,
              hubConnected: rpiState == RpiConnectionState.connected,
              hasAppliances: appliances.isNotEmpty,
              applianceNames: {for (final a in appliances) a.id: a.name},
              applianceIcons: {for (final a in appliances) a.id: a.icon},
              needsSetupIds: {
                for (final a in appliances)
                  if (needsPanelMapping(a)) a.id,
              },
            ),

            // ── ② 해야 할 일(설정 남음)·안 본 알림(설정과 같은 수) ─────────────────────
            _TodoAndUnread(setupCandidates: setupCandidates),

            // ── ③ 가전 ────────────────────────────────────────────────────
            if (!appliancesOnly) _SectionTitle('가전', key: const Key('home-appliances')),
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
                  pressHosts: pressDeviceHosts(catalog.appliances),
                ),
                verifyNoteOf: (a) => verifyNotes[a.id],
                onOpen: (a) {
                  ref.read(selectedApplianceProvider.notifier).select(a);
                  context.push('/appliance/detail/${a.id}');
                },
                onAdd: () => context.push('/appliance/add'),
              ),

            if (!appliancesOnly) const _HomeNow(),

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
          ApplianceMap a, ServerApplianceCatalog catalog) =>
      catalog.readinessFor(a);
}
