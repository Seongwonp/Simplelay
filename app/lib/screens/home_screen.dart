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
import '../widgets/routine_run.dart';
import 'routines_screen.dart' show routineSubtitle;
import '../providers/ble_provider.dart';
import '../providers/estop_provider.dart';
import '../providers/execution_status_provider.dart';
import '../widgets/demo_badge.dart';
import '../widgets/appliance_setup_card.dart';
import '../widgets/route_badge.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

// 사진 패널의 테스트 이미지 구멍은 사진을 그리는 위젯 쪽에 있다. 예전 경로
// (home_screen.dart)로 쓰던 테스트가 그대로 쓰도록 다시 내보낸다.
export '../widgets/panel_photo_view.dart' show applianceImageOverride;



/// 홈 — "우리 집"(UI 확정 §2).
///
/// 읽는 순서: **어디에 붙었나(허브 칩) → 지금 권하는 것 하나(제안 카드) →
/// 내 가전(2열 카드) → 가전 추가.** 고정 명령 버튼("즉석밥")은 두지 않는다 --
/// 메뉴는 사용자가 만든 루틴과 이력에서 나온 제안뿐이다.
///
/// 가전 카드를 눌러도 **실행하지 않는다.** 상세만 열리고, 누르는 일은 늘
/// 확인을 한 번 더 거친다.
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
    // 켜진 ThinQ 가전(서버 전원 기억 — 클라우드를 부르지 않는다). 모르면 빈 집합.
    final thinqOn = ref.watch(thinqPowerOnProvider).valueOrNull ?? const <String>{};

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

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            _Header(
              rpiState: rpiState,
              backupOnly: connected,
              onVoice: () => context.go('/voice'),
            ),
            const SizedBox(height: 16),

            // ── 연결 문제(기기에 닿지 않을 때만 맨 위) ──────────────────────
            if (serverDown) ...[
              connectionDetails,
              const SizedBox(height: 12),
            ],

            // ── DND 배너 ───────────────────────────────────────────────────
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
              const SizedBox(height: 16),
            ],

            // ── 큰 자리 하나: 제안이 있으면 제안, 없으면 첫 적격 루틴 ─────────
            // 빈 제안 문장("지금 확인할 제안이 없어요")은 두지 않는다(2026-10-13).
            if (suggestion != null)
              _SlidingCard(
                key: ValueKey(suggestion.sequenceId),
                child: _SuggestionCard(
                  suggestion: suggestion,
                  appliance: appliances
                      .where((a) => a.id == suggestion.applianceId)
                      .firstOrNull,
                  onRun: () =>
                      context.push('/suggestion/${suggestion.sequenceId}'),
                  onLater: () => _later(context, ref, suggestion),
                ),
              ),
            _HomeRoutines(
              heroAllowed: suggestion == null,
              hubConnected: rpiState == RpiConnectionState.connected,
              hasAppliances: appliances.isNotEmpty,
              applianceNames: {for (final a in appliances) a.id: a.name},
            ),

            // ── 가전 ───────────────────────────────────────────────────────
            const SizedBox(height: 24),
            Text('가전', style: AppText.title),
            const SizedBox(height: 10),
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
                  thinqOn: thinqOn.contains(a.id),
                ),
                verifyNoteOf: (a) => verifyNotes[a.id],
                onOpen: (a) {
                  ref.read(selectedApplianceProvider.notifier).select(a);
                  context.push('/appliance/detail/${a.id}');
                },
                onAdd: () => context.push('/appliance/add'),
              ),
            // 설정이 남은 가전: 독촉 카드를 맨 위에 두지 않고 목록 아래 작게.
            // 타일이 '설정이 필요해요'로 말하고, '설정 이어하기'는 그대로 둔다.
            ApplianceSetupSection(appliances: [
              for (final a in appliances)
                if (a.isCustom && !a.isDemo && !a.isThinq) a,
            ]),

            // ── 온습도 ─────────────────────────────────────────────────────
            const SizedBox(height: 16),
            sensorAsync.when(
              data: (reading) => _SensorStrip(reading: reading),
              loading: () => const _SensorStrip(reading: null),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // ── 예비 연결(기기에는 닿을 때만 아래) ──────────────────────────
            if (!serverDown) ...[
              const SizedBox(height: 8),
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

  /// '다음에' — 이번만 넘긴다(다시 받지 않기가 아니다). 실패하면 카드를 그대로
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
            _snack(context, '선택을 전달하지 못했어요. 연결을 확인해 주세요.');
          }
          return;
        }
      } catch (_) {
        if (context.mounted) {
          _snack(context, '선택을 전달하지 못했어요. 연결을 확인해 주세요.');
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

// ── 루틴(큰 자리 하나 + 간결한 행) ─────────────────────────────────────────

/// 홈의 루틴 자리(2026-10-13 B안).
///
/// 제안이 없으면 **서버가 준 루틴 목록 순서의 첫 적격 루틴**을 크게, 나머지 적격
/// 루틴은 간결한 행으로 둔다(적격: `Routine.isRunCandidate`). 자동 순위·즐겨찾기가
/// 아니고, "추천/자주 쓰는" 같은 이유를 붙이지 않는다. 제안이 있으면 큰 자리는 제안의
/// 것이고 루틴은 행으로만 보인다. '실행하기'는 승인 카드만 만든다(루틴 탭과 같은 경로).
class _HomeRoutines extends ConsumerStatefulWidget {
  const _HomeRoutines({
    required this.heroAllowed,
    required this.hubConnected,
    required this.hasAppliances,
    required this.applianceNames,
  });

  final bool heroAllowed;
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

  static const _maxRows = 4;

  Future<void> _run(String id) async {
    if (_runningId != null) return;
    setState(() {
      _runningId = id;
      _error = null;
    });
    try {
      final error = await runRoutineNow(context, ref, id);
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
          padding: const EdgeInsets.only(top: 12),
          child: Text('루틴을 불러오지 못했어요.',
              style: TextStyle(fontSize: 15, color: context.appMuted)),
        );
      },
      data: (routines) {
        final candidates = [
          for (final r in routines)
            if (r.isRunCandidate) r,
        ];
        if (routines.isEmpty) {
          // 0대면 가전 추가가 첫 과업이다 — 루틴 입구를 겹쳐 두지 않는다.
          if (!widget.hasAppliances) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 12),
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
        if (candidates.isEmpty) return const SizedBox.shrink();
        final hero = widget.heroAllowed ? candidates.first : null;
        final rest = [
          for (final r in candidates)
            if (r != hero) r,
        ];
        final shown = rest.take(_maxRows).toList();
        final busy = _runningId != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hero != null) ...[
              _RoutineHeroCard(
                routine: hero,
                subtitle: routineSubtitle(hero, widget.applianceNames),
                running: _runningId == hero.id,
                busy: busy,
                onRun: () => _run(hero.id!),
              ),
              if (_errorFor == hero.id && _error != null) _ErrorLine(_error!),
            ],
            if (shown.isNotEmpty) const SizedBox(height: 8),
            for (final r in shown) ...[
              _RoutineQuickRow(
                routine: r,
                subtitle: routineSubtitle(r, widget.applianceNames),
                running: _runningId == r.id,
                busy: busy,
                onRun: () => _run(r.id!),
              ),
              if (_errorFor == r.id && _error != null) _ErrorLine(_error!),
            ],
            if (rest.length > shown.length)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.go('/routines'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text('루틴 ${rest.length - shown.length}개 더 보기'),
                ),
              ),
          ],
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
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: TextStyle(fontSize: 15, color: context.appDanger)),
      );
}

Widget _runButton({
  required Key key,
  required Routine routine,
  required bool running,
  required bool busy,
  required VoidCallback onRun,
  required bool primary,
}) {
  final child = running
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : const Text('실행하기');
  return Semantics(
    // 화면 글자는 '실행하기'로 같아도 읽을 때는 어느 루틴인지 구별된다.
    label: '${routine.name} 실행하기',
    // 제 노드를 갖게 한다 — 아니면 카드 글자와 한 덩어리로 합쳐 읽힌다.
    container: true,
    button: true,
    enabled: !busy,
    excludeSemantics: true,
    child: primary
        ? FilledButton(
            key: key,
            onPressed: busy ? null : onRun,
            style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
            child: child,
          )
        : OutlinedButton(
            key: key,
            onPressed: busy ? null : onRun,
            style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
            child: child,
          ),
  );
}

/// 첫 적격 루틴 — 이름·조건·대상과 실행하기 하나.
class _RoutineHeroCard extends StatelessWidget {
  const _RoutineHeroCard({
    required this.routine,
    required this.subtitle,
    required this.running,
    required this.busy,
    required this.onRun,
  });

  final Routine routine;
  final String subtitle;
  final bool running;
  final bool busy;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('home-routine-hero'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.appSurfaceLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 루틴마다 제 접근성 노드(2026-10-14, 발견 5) — 이웃 루틴 글과 한 덩어리로 읽히지 않게.
            Semantics(
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(routine.name,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  // 낱말 중간에서 꺾이지 않게("1단 / 계", 2026-10-14 발견 7).
                  Text(keepWordsTogether(subtitle),
                      style: TextStyle(fontSize: 15, color: context.appMuted)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _runButton(
              key: Key('home-routine-run-${routine.id}'),
              routine: routine,
              running: running,
              busy: busy,
              onRun: onRun,
              primary: true,
            ),
          ],
        ),
      );
}

/// 나머지 적격 루틴 — 이름과 실행하기만. 카드로 감싸지 않는다.
class _RoutineQuickRow extends StatelessWidget {
  const _RoutineQuickRow({
    required this.routine,
    required this.subtitle,
    required this.running,
    required this.busy,
    required this.onRun,
  });

  final Routine routine;
  final String subtitle;
  final bool running;
  final bool busy;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    // 루틴마다 제 접근성 노드(2026-10-14, 발견 5) — 세 줄이 한 노드로 묶여 한꺼번에 읽혔다.
    final text = Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(routine.name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          // 낱말 중간에서 꺾이지 않게("1단 / 계", 2026-10-14 발견 7).
          Text(keepWordsTogether(subtitle),
              style: TextStyle(fontSize: 14, color: context.appMuted)),
        ],
      ),
    );
    final button = _runButton(
      key: Key('home-routine-run-${routine.id}'),
      routine: routine,
      running: running,
      busy: busy,
      onRun: onRun,
      primary: false,
    );
    return Padding(
      key: Key('home-routine-row-${routine.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      // 큰 글씨에서는 버튼을 아래 줄로 내린다 — 이름이 한 글자씩 꺾이지 않게.
      child: MediaQuery.textScalerOf(context).scale(1) > 1.3
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 6), button],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 8),
                button,
              ],
            ),
    );
  }
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
      RpiConnectionState.connected => ('허브 연결됨', context.appPrimary),
      RpiConnectionState.keyRequired => ('허브 키가 필요해요', context.appWarning),
      RpiConnectionState.checking ||
      RpiConnectionState.unconfigured =>
        ('허브 확인 중', context.appMuted),
      RpiConnectionState.unreachable =>
        (backupOnly ? '예비 연결만 돼요' : '허브에 닿지 않아요', context.appWarning),
    };
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
    // 말로 하는 길 -- 누르기 어려운 사용자에게 길이 하나뿐이면 안 된다.
    final voice = IconButton(
      onPressed: onVoice,
      tooltip: '말로 조작하기',
      icon: Icon(Icons.mic_none_rounded, color: context.appPrimary),
    );
    // 큰 글씨에서는 칩을 제목 아래 줄로 내린다. 한 줄에 두면 제목과 칩이 서로
    // 폭을 뺏어 "우리 / 집"처럼 한 글자씩 꺾인다.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('우리 집', style: AppText.heading)),
            voice,
          ]),
          const SizedBox(height: 6),
          chip,
        ],
      );
    }
    // 제목은 제 폭만 쓰고 남는 자리를 칩에 준다 -- 칩 문구가 두 줄로 꺾이지 않게.
    return Row(
      children: [
        Text('우리 집', style: AppText.heading),
        const SizedBox(width: 12),
        Expanded(
          child: Align(alignment: Alignment.centerRight, child: chip),
        ),
        voice,
      ],
    );
  }
}

// ── 제안 카드 ─────────────────────────────────────────────────────────────

/// 제안 한 장 — 무엇을(가전·이름), 왜 지금(근거 한 줄), 그리고 두 버튼.
///
/// '실행하기'는 **바로 누르지 않는다.** 누를 순서와 대상 가전을 보여 주는
/// 확인 화면을 연다 -- 승인은 거기서 한 번이고, 승인 내용이 바뀌면(409)
/// 그 화면이 다시 확인하게 한다.
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.appPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.appPrimary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(a?.icon ?? Icons.lightbulb_outline,
                  size: 18, color: context.appPrimary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  a == null ? '제안' : a.displayName,
                  style: TextStyle(fontSize: 14, color: context.appMuted),
                ),
              ),
              if (suggestion.isDemo) const DemoBadge(),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            suggestion.title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          if (why.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(why, style: TextStyle(fontSize: 15, color: context.appMuted)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // 화면 글자는 짧게, 읽는 이름에는 대상을(2026-10-14, 발견 5) — '실행하기'만으로는 무엇을 하는지 모른다.
              Semantics(
                label: '${suggestion.title} 실행하기',
                container: true,
                button: true,
                excludeSemantics: true,
                child: FilledButton(
                  onPressed: onRun,
                  style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
                  child: const Text('실행하기'),
                ),
              ),
              Semantics(
                label: '${suggestion.title} 다음에',
                container: true,
                button: true,
                excludeSemantics: true,
                child: OutlinedButton(
                  onPressed: onLater,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                  child: const Text('다음에'),
                ),
              ),
            ],
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
    final cards = <Widget>[
      for (final a in appliances)
        _ApplianceCard(
          appliance: a,
          name: names[a.id] ?? a.name,
          status: statusOf(a),
          verifyNote: verifyNoteOf(a),
          onTap: () => onOpen(a),
        ),
      _AddCard(onTap: onAdd),
    ];
    // 큰 글씨(150% 넘음)에서는 한 칸씩. 두 칸에 두면 가전 이름이 한 글자씩 꺾인다.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.5) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i + 1 < cards.length ? 10 : 0),
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
            padding: EdgeInsets.only(bottom: i + 2 < cards.length ? 10 : 0),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[i]),
                  const SizedBox(width: 10),
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

  /// '확인 주행' 보조 줄. 상태 줄과 따로 그리고, 접근성 이름에도 넣는다.
  final String? verifyNote;

  /// 타일 상태 한 줄. "돌아가는 중"은 없다 — 버튼 조작 진행·준비 여부까지만.
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
    final (Color color, IconData? icon) = switch (s.tone) {
      TileTone.active => (context.appPrimary, null),
      TileTone.attention => (context.appWarning, Icons.error_outline),
      TileTone.unknown => (context.appMuted, Icons.help_outline),
      TileTone.ready => (context.appMuted, null),
      TileTone.on => (context.appSuccess, Icons.power_settings_new),
    };
    return Semantics(
      button: true,
      // excludeSemantics라 아래 글자가 따로 읽히지 않는다 — 상태를 이름에 함께 넣는다.
      label: [
        if ((a.location ?? '').isNotEmpty) '${a.location} $name' else name,
        if (a.isThinq) 'ThinQ',
        if (a.isDemo) '데모',
        if (s.text.isNotEmpty) s.text,
        if (s.detail case final d?) d,
        if (verifyNote case final v?) v,
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        color: context.appSurfaceLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('appliance-card-${a.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? context.appPrimary : context.appBorderSubtle,
                width: active ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 회색은 쉬는 중, 강조색은 버튼 조작 중. 색만으로 말하지 않고
                    // 아래에 상태 글자를 같이 둔다.
                    Icon(a.icon,
                        size: 28,
                        color: active ? context.appPrimary : context.appMuted),
                    const Spacer(),
                    if (a.isThinq) const RouteBadge(label: 'ThinQ'),
                    if (a.isDemo) const DemoBadge(),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  name,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700),
                ),
                if ((a.location ?? '').isNotEmpty)
                  Text(a.location!,
                      style: TextStyle(fontSize: 14, color: context.appMuted)),
                // 평소(실행 가능)는 상태 줄을 두지 않는다(빈 문자열, 2026-10-14 UX).
                if (s.text.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  key: Key('appliance-status-${a.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(icon, size: 16, color: color),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        // "연결을 확인해 주 / 세요"처럼 낱말 중간에서 꺾이지 않게(2026-10-14 발견 7).
                        keepWordsTogether(s.text),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
                ],
                if (s.detail case final d?)
                  Text(
                    d,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: context.appMuted),
                  ),
                if (verifyNote case final v?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      v,
                      key: Key('appliance-verify-note-${a.id}'),
                      style: TextStyle(fontSize: 13, color: context.appMuted),
                    ),
                  ),
                if (s.progress) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 5,
                      value:
                          total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                    ),
                  ),
                ],
              ],
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
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 110),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.appBorderSubtle),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 28, color: context.appMuted),
                const SizedBox(height: 4),
                Text('가전 추가',
                    style: TextStyle(fontSize: 15, color: context.appMuted)),
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
      ServerCatalogStatus.loading => '기기의 가전 목록을 확인하는 중이에요.',
      ServerCatalogStatus.failed => '기기의 가전 목록을 가져오지 못했어요. 연결을 확인해 주세요.',
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
          const SizedBox(height: 6),
          Text(
            '조작부 사진을 찍고 버튼을 짚어 등록하면\n여기서 상태를 보고 조작할 수 있어요.',
            style: TextStyle(fontSize: 16, color: context.appMuted),
          ),
          if (note case final note?) ...[
            const SizedBox(height: 8),
            Text(note, style: TextStyle(fontSize: 14, color: context.appMuted)),
          ],
          const SizedBox(height: 16),
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
            ? ('제안·기록이 멈췄어요', context.appWarning,
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
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // 기술 용어를 여기 쓰지 않는다. `RPi 서버`·주소 입력·
                      // 재시도는 눌렀을 때만 나온다.
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  Text(
                    _open ? '접기' : '확인하기',
                    style: TextStyle(
                      fontSize: 15,
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
          const SizedBox(height: 4),
          // 닿는 기기를 "연결됐어요" 카드로 다시 말하지 않는다.
          if (_serverDown) _RpiStatusCard(state: widget.rpiState),
          // 예비 연결은 **꺼져 있을 때만** 말한다.
          if (!widget.bleConnected) ...[
            if (_serverDown) const SizedBox(height: 12),
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
            const SizedBox(width: 4),
            Text(
              '${temp.toStringAsFixed(1)}°C',
              style: TextStyle(fontSize: 13, color: context.appMuted),
            ),
          ],
          if (temp != null && hum != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('·', style: TextStyle(color: context.appMuted)),
            ),
          if (hum != null) ...[
            Icon(Icons.water_drop_outlined, size: 14, color: context.appMuted),
            const SizedBox(width: 4),
            Text(
              '${hum.toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 13, color: context.appMuted),
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
    if (diff.isNegative) return '해제됨';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 남음' : '$h시간 남음';
    }
    return '${diff.inMinutes + 1}분 남음';
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.do_not_disturb_on, color: context.appWarning, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                // 끝나는 시각을 함께 적는다(2026-10-14 마감 확인 A5) — 남은 시간만으로는 '언제까지'를 셈해야 한다.
                '방해 금지 중 · ${pauseEndClock(until)}까지 · $_remaining',
                style: TextStyle(color: context.appWarning, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: context.appWarning,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 48),
              ),
              child: const Text('해제', style: TextStyle(fontSize: 13)),
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
        title: const Text('허브 주소'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '예: 192.168.0.10',
            helperText: '공유기 관리 화면에서 허브 주소를 확인해 주세요.',
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
          context.appWarning, Icons.key, '허브 키가 필요해요', '설정에서 허브 키를 입력해 주세요.'
        ),
      RpiConnectionState.connected => (
          context.appSuccess,
          Icons.wifi,
          '기기와 연결됐어요',
          '말이나 버튼으로 조작할 수 있어요',
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          Icons.sync,
          '연결 확인 중…',
          'simplelay.local에 접속하고 있어요',
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
          Icons.wifi_off,
          '허브에 닿지 않아요',
          '같은 Wi-Fi인지 확인하거나 주소를 직접 입력하세요',
        ),
      RpiConnectionState.unconfigured => (
          context.appMuted,
          Icons.wifi_off,
          '허브 주소를 입력해 주세요',
          '설정에서 서버 주소를 입력하세요',
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
        padding: const EdgeInsets.all(16),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('주소 입력', style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(rpiConnectionProvider.notifier).check(),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('재시도', style: TextStyle(fontSize: 13)),
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
          padding: const EdgeInsets.all(16),
          child: _StatusCardBody(
            icon: Icons.bluetooth_disabled,
            color: context.appMuted,
            iconBackground: Theme.of(context).colorScheme.surfaceContainerHigh,
            title: '예비 연결이 꺼져 있어요',
            subtitle: '연결해 두면 서버가 안 될 때도 조작할 수 있어요.',
            actions: [
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('연결', style: TextStyle(fontSize: 13)),
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
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
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
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, children: actions),
      ],
    );
  }
}

// ── 슬라이딩 카드 애니메이션 ───────────────────────────────────────────────

class _SlidingCard extends StatefulWidget {
  const _SlidingCard({super.key, required this.child});
  final Widget child;

  @override
  State<_SlidingCard> createState() => _SlidingCardState();
}

class _SlidingCardState extends State<_SlidingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<Offset> _offset = Tween(
    begin: const Offset(0, 0.12),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _offset, child: widget.child),
      );
}
