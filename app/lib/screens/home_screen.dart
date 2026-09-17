import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/navigation_provider.dart';
import '../widgets/appliance_portrait.dart';
import '../widgets/demo_badge.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 골든 테스트가 실제 사진 렌더를 확인하기 위해 끼우는 이미지.
///
/// 파일 이미지는 위젯 테스트에서 디코딩되지 않아, 이 구멍이 없으면 사진
/// 화면의 크롭·BoxFit·모서리가 아무 데서도 검증되지 않는다. 앱 실행 중에는
/// 항상 null이다.
@visibleForTesting
ImageProvider? applianceImageOverride;

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

    final connected = connection == BleConnectionState.connected;
    final rpiOnline = rpiState == RpiConnectionState.connected;
    final dndActive = dndUntil != null && dndUntil.isAfter(DateTime.now());

    final appliance = ref.watch(selectedApplianceProvider);
    // 홈은 **이 폰에 설치된 가전**만 센다. 예시 템플릿을 섞어 세면 아직
    // 아무것도 등록하지 않은 사람의 홈에 남의 가전이 놓인다.
    final appliances = ref.watch(installedAppliancesProvider);

    // 연결 문제는 **정도에 따라 자리가 다르다.** 기기(서버)에 닿지 않으면
    // 제안·기록·실행 상태가 모두 멈추므로 맨 위에서 먼저 말한다. 예비
    // 연결만 꺼진 것은 지금 조작에 지장이 없으니 아래에 조용히 둔다 --
    // 예전에는 둘을 같은 빨간 줄로 맨 아래에 두어, 같은 화면에 "조작 가능"과
    // "연결 설정이 필요해요"가 함께 떠서 어느 쪽을 믿을지 알 수 없었다.
    final serverDown = !rpiOnline;
    final connectionDetails =
        _ConnectionDetails(rpiState: rpiState, bleConnected: connected);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SimpleLay'),
        // 앱바에 아이콘을 몰아두지 않는다. 뜻을 추측해야 하는 그림이 셋씩
        // 붙어 있으면, 디지털에 익숙하지 않은 사용자에게는 그 줄 전체가
        // 읽을 수 없는 영역이 된다.
        //
        // 알림함은 탭바로, 방해 금지는 설정으로 옮겼다. 연결 상태 칩은
        // 아래 가전 상태 문장이 같은 말을 하므로 없앴다 -- 같은 사실을
        // 두 군데서 다르게 말하면 어느 쪽을 믿을지 알 수 없다.
        actions: [
          // 실행 기록 (공감지능 근거 + 폐루프 재시도 기록). 하단 탭에 자리가
          // 없어 여기 남긴다 -- 이제 혼자라 붐비지 않는다.
          IconButton(
            onPressed: () => context.push('/history'),
            icon: const Icon(Icons.history),
            tooltip: '실행 기록',
          ),
          const SizedBox(width: 4),
        ],
      ),
      // 순서가 곧 이 화면의 주장이다: **무엇을 조작하는가 → 지금 되는가 →
      // 확인할 것 → (필요할 때만) 연결 사정.** 예전에는 연결 카드 두 장이
      // 위를 차지해서, 실제로 조작할 수 있는 상태에서도 "뭔가 더 연결해야
      // 하는 앱"으로 보였고 대상 가전은 설정에 들어가야 알 수 있었다.
      // 구획을 카드로 나누지 않는다. 제목과 여백으로 나눈다 -- 모든 것을
      // 둥근 카드에 넣으면 정보의 깊이가 전부 같아 보이고, 화면에 편집
      // 방향이 사라진다.
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          // ── 연결 문제(기기에 닿지 않을 때만 맨 위) ──────────────────────
          if (serverDown) ...[
            connectionDetails,
            const SizedBox(height: 12),
          ],

          // ── 가전 고르기 ──────────────────────────────────────────────────
          // 등록된 가전이 하나뿐이면 고를 것이 없다. 줄을 통째로 뺀다.
          if (appliances.length > 1) ...[
            _ApplianceRow(appliances: appliances, selected: appliance),
            const SizedBox(height: 20),
          ],

          // ── 지금 조작할 가전 ─────────────────────────────────────────────
          // 설치한 가전이 0대인 홈은 **고장이 아니라 시작점**이다. 경고색도
          // 오류 문구도 쓰지 않고, 다음에 할 일 하나만 놓는다. 아래의 제안·
          // 센서·연결 구획은 그대로 둔다 -- 가전이 없어도 홈은 홈이다.
          if (appliance == null)
            _NoApplianceStage(onAdd: () => context.push('/appliance/new'))
          else
            _ApplianceStage(
              appliance: appliance,
              reachable: connected || rpiOnline,
              backupOnly: connected && !rpiOnline,
              imageOverride: applianceImageOverride,
              onManual: () => context.push('/manual-control'),
              // 편집기는 아직 '새 가전 만들기'만 받는다. 기존 가전에 사진을
              // 붙이는 경로가 생기기 전까지는 가전 관리가 있는 설정으로
              // 보낸다 -- 없는 화면으로 보내거나, 새 가전을 만들게 하지 않는다.
              onAddPhoto: () =>
                  ref.read(currentTabIndexProvider.notifier).state = 3,
            ),

          // ── DND 배너 ─────────────────────────────────────────────────────
          if (dndActive) ...[
            const SizedBox(height: 20),
            _DndBanner(
              until: dndUntil,
              onClear: () => ref.read(dndProvider.notifier).clear(),
            ),
          ],

          // 학습 통계 카드(AI가 N개 패턴을 발견했습니다 + KPI 3칸)는 없앴다.
          // 제품이 자기가 똑똑하다고 광고하는 자리였고, 사용자가 그걸로 할 수 있는
          // 판단이 없었다. 게다가 '총 동작 N회'로 표시하던 값은 실제로는 대기 중인
          // 제안들의 단계 수 합계라, 라벨과 뜻이 아예 달랐다.
          //
          // 제안이 없을 때 큰 빈 카드를 두지 않는다. 한 줄이면 충분하다.
          const SizedBox(height: 28),
          _SectionTitle('제안'),
          const SizedBox(height: 4),
          if (suggestions.isEmpty)
            _EmptyLine(dndActive: dndActive)
          else
            ...suggestions.map(
              (s) => _SlidingCard(
                child: _SuggestionRow(
                  suggestion: s,
                  onTap: () => context.push('/suggestion/${s.sequenceId}'),
                ),
              ),
            ),

          // ── 온습도 ───────────────────────────────────────────────────────
          sensorAsync.when(
            data: (reading) => _SensorStrip(reading: reading),
            loading: () => const _SensorStrip(reading: null),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // ── 예비 연결(기기에는 닿을 때만 아래) ──────────────────────────
          if (!serverDown) ...[
            const SizedBox(height: 16),
            connectionDetails,
          ],
        ],
      ),
    );
  }
}

// ── 구획 ──────────────────────────────────────────────────────────────────

/// 섹션 제목. 카드로 감싸지 않고 제목과 여백으로 구획을 만든다.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: AppText.title);
}

// ── 가전 고르기 (한 줄) ────────────────────────────────────────────────────

/// 등록된 가전을 가로 한 줄로. 선택은 **넓은 색면이 아니라** 테두리와
/// 글자 굵기로 나타낸다 -- 색면으로 칠하면 화면에서 가장 강한 요소가
/// "고르는 줄"이 되어 정작 주인공인 가전을 이긴다.
class _ApplianceRow extends ConsumerWidget {
  const _ApplianceRow({required this.appliances, required this.selected});

  final List<ApplianceMap> appliances;

  /// 아직 아무것도 고르지 않았으면 null. 이 줄은 2대 이상일 때만 나오지만,
  /// 복원 중인 한 프레임 동안 null일 수 있다.
  final ApplianceMap? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 가로 스크롤을 쓰지 않는다. 마지막 칩이 화면 끝에서 잘려 고장난
    // 것처럼 보이고, 가로로 밀어야 한다는 것 자체가 잘 발견되지 않는다.
    // 줄바꿈하면 200%로 키워도 전부 보인다.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in appliances)
          Builder(builder: (context) {
            final on = a.id == selected?.id;
            return Semantics(
            button: true,
            selected: on,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () =>
                  ref.read(selectedApplianceProvider.notifier).select(a),
              child: Container(
                // alignment를 주면 느슨한 제약에서 가용 폭을 다 차지해
                // 칩이 화면 폭만큼 늘어난다. 폭은 Row(min)가 정한다.
                // 세로 여백으로 최소 터치 대상(48)을 맞춘다.
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: on ? context.appPrimary : context.appBorderSubtle,
                    width: on ? 2 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon,
                        size: 18,
                        color: on ? context.appPrimary : context.appMuted),
                    const SizedBox(width: 7),
                    Text(
                      a.displayName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                        color:
                            on ? context.appPrimary : context.appOnSurfaceSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ── 지금 조작할 가전 ──────────────────────────────────────────────────────

/// 화면의 주인공. 실제 가전 사진(없으면 실루엣) + 이름 + 지금 되는지 한 줄.
///
/// **내부 축(전송·모션·센서·보정)을 여기에 늘어놓지 않는다.** 그건 장치
/// 상태지 사용자가 바로 손댈 수 있는 것이 아니라서, 막대 넷으로 보여주면
/// 기술 대시보드가 된다. 여기서는 가장 중요한 사유 하나만 말하고 상세로
/// 넘긴다.
/// 설치한 가전이 0대인 홈의 첫 구획.
///
/// 빈 자리를 남기거나 예시 가전을 세워 두지 않는다. 예시를 세우면 사용자는
/// 자기가 등록하지도 않은 전자레인지가 어디서 왔는지 묻게 되고, 그 순간
/// 앱이 말하는 다른 상태도 못 믿게 된다.
class _NoApplianceStage extends StatelessWidget {
  const _NoApplianceStage({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Icon(Icons.add_home_outlined,
                size: 72, color: context.appMuted),
          ),
          const SizedBox(height: 16),
          Text('아직 등록한 가전이 없어요', style: AppText.heading),
          const SizedBox(height: 6),
          Text(
            '조작하고 싶은 가전을 추가하면\n여기서 상태를 보고 바로 조작할 수 있어요.',
            style: TextStyle(fontSize: 16, color: context.appMuted),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('가전 추가'),
          ),
        ],
      );
}

class _ApplianceStage extends StatelessWidget {
  const _ApplianceStage({
    required this.appliance,
    required this.reachable,
    this.backupOnly = false,
    required this.onManual,
    required this.onAddPhoto,
    this.imageOverride,
  });

  /// 골든이 실제 사진 렌더를 확인하기 위한 구멍. 앱 실행에는 항상 null이다.
  final ImageProvider? imageOverride;

  final ApplianceMap appliance;

  /// BLE나 서버 중 하나로라도 닿는가.
  final bool reachable;

  /// 서버에는 닿지 않고 예비 연결(BLE)로만 닿는가. 조작은 되지만 제안·기록은
  /// 오지 않으므로, "조작할 수 있어요"만 말하면 위의 연결 경고와 어긋난다.
  final bool backupOnly;
  final VoidCallback onManual;
  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context) {
    final (line, warn) = _status();
    final hasPhoto = imageOverride != null ||
        (appliance.photoPath != null && appliance.photoPath!.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: AppliancePortrait(
            appliance: appliance,
            imageOverride: imageOverride,
            // 화면 폭에 맞추되 지나치게 커지지 않게 둔다.
            size: (MediaQuery.sizeOf(context).width * 0.52).clamp(150.0, 220.0),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Flexible(child: Text(appliance.displayName, style: AppText.heading)),
            if (appliance.isDemo) ...[
              const SizedBox(width: 8),
              const DemoBadge(),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              warn ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: warn ? context.appDanger : context.appMuted,
            ),
            const SizedBox(width: 6),
            // 사유가 길어지면 줄바꿈한다 -- 자르면 복구 방법이 사라진다.
            Expanded(
              child: Text(
                line,
                style: TextStyle(
                  fontSize: 16,
                  color: warn ? context.appDanger : context.appMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 말로 하는 경로는 탭바 가운데에 있다. 여기에는 **다른 경로**를 둔다 --
        // 말이 잘 안 되는 사용자에게 길이 하나뿐이면 안 된다.
        FilledButton.icon(
          onPressed: onManual,
          icon: const Icon(Icons.touch_app, size: 20),
          label: const Text('버튼으로 조작'),
        ),
        if (!hasPhoto)
          // 주 행동과 경쟁하지 않게 아래에 작게. 거절해도 그대로 쓸 수 있다.
          Align(
            alignment: Alignment.centerLeft,
            child: AddPhotoHint(onTap: onAddPhoto),
          ),
      ],
    );
  }

  /// (문구, 경고인가). **모르는 것을 준비됐다고 말하지 않는다** --
  /// 서버가 준비 상태를 알려준 경우에만 못 쓴다고 단정한다.
  (String, bool) _status() {
    if (appliance.readinessKnown && !appliance.canExecute) {
      final why = appliance.readinessReasons;
      if (why.isNotEmpty) return (why.first, true);
      return (
        appliance.readiness == 'disconnected'
            ? '아직 연결되지 않았어요'
            : '아직 준비가 끝나지 않았어요',
        true
      );
    }
    if (!reachable) return ('기기와 연결되면 조작할 수 있어요', false);
    if (backupOnly) return ('예비 연결로 조작할 수 있어요', false);
    return ('조작할 수 있어요', false);
  }
}

// ── 제안 (카드가 아니라 행) ────────────────────────────────────────────────

/// 제안 하나를 **행**으로 둔다. 카드로 감싸면 화면의 다른 카드들과 깊이가
/// 같아져서, 지금 확인해야 할 것이 눈에 띄지 않는다.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onTap});

  final Suggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 홈의 행은 질문이 아니다. 목록에서 물어보고 상세에서
                    // 또 물으면 두 번 묻는 꼴이고, 사용자가 부른 말을 어색한
                    // 물음으로 고쳐 쓰면(`즉석밥 데워줘, 지금 할까요?`) 오히려
                    // 자기가 한 말처럼 안 들린다. 무엇을 하는 것인지만 쓴다.
                    Text(
                      suggestion.label,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _stepPreview(suggestion),
                      style: TextStyle(fontSize: 14, color: context.appMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, color: context.appMuted),
            ],
          ),
        ),
      );
}

/// 눌릴 버튼을 **사용자 언어로** 보여준다. `BT-08`은 아무 뜻이 없고,
/// "3단계 동작"은 몇 번 움직이는지만 알려줄 뿐 무엇을 누르는지는 알려주지
/// 않는다 -- 맡길지 판단하려면 그쪽이 필요하다.
String _stepPreview(Suggestion suggestion) {
  if (suggestion.steps.isEmpty) return '누를 버튼을 확인하려면 눌러 보세요';
  return suggestion.steps.map(readableStep).join(' → ');
}

/// 제안이 없을 때. 큰 빈 카드를 두지 않는다 -- 한 줄이면 충분하다.
class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.dndActive});

  final bool dndActive;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          dndActive ? '방해 금지 중이라 제안을 쉬고 있어요.' : '지금 확인할 제안이 없어요.',
          style: TextStyle(fontSize: 15, color: context.appMuted),
        ),
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

  bool get _serverDown => widget.rpiState != RpiConnectionState.connected;

  bool get _hasProblem => _serverDown || !widget.bleConnected;

  @override
  Widget build(BuildContext context) {
    // 문제가 없으면 이 줄 자체를 두지 않는다. 잘 되고 있는 것을 알리는
    // 줄은 화면을 관리 도구로 되돌릴 뿐, 사용자가 그걸로 할 판단이 없다.
    if (!_hasProblem) return const SizedBox.shrink();

    // 기기에 닿지 않으면 경고색, 예비 연결만 꺼졌으면 보조색. 둘 다 끊긴
    // 것과 예비 연결로 버티는 것도 문장을 나눈다 -- 조작은 되는데 "연결
    // 설정이 필요해요"라고만 하면 무엇이 안 되는지 알 수 없다.
    final (String label, Color color, IconData icon) = !_serverDown
        ? ('예비 연결 꺼짐', context.appMuted, Icons.bluetooth_disabled)
        : widget.bleConnected
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
                '방해 금지 중 · $_remaining',
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
        title: const Text('RPi 서버 주소'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '예: 192.168.0.10',
            helperText: 'RPi5 화면이나 공유기 관리 페이지에서 IP를 확인할 수 있어요.',
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
          'RPi 서버에 연결할 수 없어요',
          '같은 Wi-Fi인지 확인하거나 주소를 직접 입력하세요',
        ),
      RpiConnectionState.unconfigured => (
          context.appMuted,
          Icons.wifi_off,
          'RPi 서버 미설정',
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

/// 홈의 주 행동 버튼. 떠 있되 구석의 작은 알약이 아니라 화면 폭을 넉넉히 쓴다.
/// 주 경로가 막혔을 때 갈 수 있는 다른 길. 주 행동보다 조용하되
/// 발견은 되어야 하므로 같은 자리(하단 중앙)에 함께 둔다.
// ── 슬라이딩 카드 애니메이션 ───────────────────────────────────────────────

class _SlidingCard extends StatefulWidget {
  const _SlidingCard({required this.child});
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
