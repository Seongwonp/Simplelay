import '../models/clock_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../providers/execution_status_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// ThinQ 가전 상세의 '지금 상태' 카드(2026-10-15, 사용자 요청 동결 예외).
///
/// 못 읽었으면 이유를 말하고 값을 지어내지 않는다. 읽은 시각을 'HH:MM에 읽음'로
/// 같이 적는다 — ThinQ 값은 그 시각의 것이지 지금 이 순간의 보장이 아니다.
///
/// 공기청정기는 전원·풍량·운전 모드를 여기서 바꾼다(같은 날 사용자 요청). **누르면
/// 곧바로 보내지 않고 한 번 묻는다** — 승인하면 POST /thinq/command, 결과는 실행
/// 상태 화면이 확인 단계와 함께 말하고, 돌아오면 상태를 다시 읽는다. 상태를 못 읽었을
/// 때는 지금 값을 모르므로 조작 줄을 내걸지 않는다.
///
/// 외부 검토 반영(같은 날):
/// - 전원이 꺼져 있으면 풍량·운전 모드 줄을 내걸지 않는다(켜야 바뀐다). 켜기만 남기고,
///   스스로 켜지 않는다. 미세먼지 칸이 없으면 왜 없는지 한 줄로 말한다.
/// - 요청 하나가 끝나기 전에는 다른 값을 보내지 않는다(칩을 잠근다).
/// - 응답 없이 끝난 요청(시간 초과·연결 끊김)은 '보내지 못했다'고 단정하지 않는다 —
///   허브가 이미 받았을 수 있다. 결과를 모른다고 말하고 상태를 다시 읽는다.
class ThinqStateCard extends ConsumerStatefulWidget {
  const ThinqStateCard({
    super.key,
    required this.applianceId,
    this.applianceName = '가전',
  });

  final String applianceId;
  final String applianceName;

  @override
  ConsumerState<ThinqStateCard> createState() => _ThinqStateCardState();
}

/// 전원이 꺼져 있을 때 전원 줄 아래에 놓는 문장.
const kThinqPowerOffNote = '전원이 꺼져 있어요. 켜야 바람 세기와 운전 방식을 바꿀 수 있어요.';

/// 응답 없이 끝난 조작 요청(시간 초과·연결 끊김·응답 해석 실패).
const kThinqUnknownOutcome = '바뀌었는지 몰라요. 새로 보기를 눌러 봐 주세요.';

class _ThinqStateCardState extends ConsumerState<ThinqStateCard> {
  /// 묻기부터 응답(또는 실행 상태 화면에서 돌아옴)까지 — 이 동안 다른 조작을 받지 않는다.
  bool _sending = false;

  String get applianceId => widget.applianceId;
  String get applianceName => widget.applianceName;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(thinqStatusProvider(applianceId));
    final status = async.valueOrNull;
    final loading = async.isLoading;
    final locked = loading || _sending;

    Widget body;
    if (status == null) {
      body = Text('LG 앱에서 불러오고 있어요…',
          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted));
    } else if (!status.ok) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: context.appWarning),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text('지금 상태를 못 불러왔어요. ${status.failure}',
                style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
          ),
        ],
      );
    } else {
      final rows = thinqStateRows(status.state);
      final dustNote = thinqDustNote(status.state);
      final powerOff = thinqPowerOff(status.state);
      final mock = status.executionMode == 'mock';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty)
            Text('보여 줄 상태가 없어요',
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
          else
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(label,
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(value,
                          style: const TextStyle(
                              fontSize: AppFont.caption, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
          if (dustNote != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(dustNote,
                  key: const Key('thinq-dust-note'),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            ),
          if (status.readAt != null) ...[
            const SizedBox(height: AppSpace.sm),
            Semantics(
              container: true,
              label: '지금 상태, ${thinqReadTimeSpoken(status.readAt!)} 기준'
                  '${mock ? ', 연습' : ''}',
              excludeSemantics: true,
              child: Text(
                thinqReadTimeLine(status.readAt!, mock: mock),
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
              ),
            ),
          ],
          for (final control in thinqControlsFor(status.state))
            // 꺼져 있으면 전원 줄만 — 풍량·운전 모드는 켜야 바뀐다(스스로 켜지 않는다).
            if (!powerOff || control.action == 'set_power') ...[
              const SizedBox(height: AppSpace.lg),
              Text(control.label,
                  style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final (value, word) in control.choices)
                    ChoiceChip(
                      key: Key('thinq-set-${control.action}-$value'),
                      // 읽는 이름에 줄 이름까지 — '자동'이 풍량인지 운전 모드인지 갈리게.
                      label: Semantics(
                        label: control.chipSemantics(word),
                        excludeSemantics: true,
                        child: Text(word, style: const TextStyle(fontSize: AppFont.caption)),
                      ),
                      selected: control.current == value,
                      // 지금 값도 흐리게 만들지 않는다(꺼진 버튼처럼 보이지 않게) — 눌러도 아무것도 안 한다.
                      onSelected: locked
                          ? null
                          : (_) {
                              if (control.current == value) return;
                              _change(control, value, word);
                            },
                    ),
                ],
              ),
              if (powerOff && control.action == 'set_power') ...[
                const SizedBox(height: AppSpace.sm),
                Text(kThinqPowerOffNote,
                    key: const Key('thinq-power-off-note'),
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
              ],
            ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: context.appSurfaceLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: DefaultTextStyle.merge(
        style: AppText.body,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    status?.executionMode == 'mock' ? '지금 상태 (연습)' : '지금 상태',
                    style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  key: const Key('thinq-status-refresh'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: locked
                      ? null
                      : () => ref.invalidate(thinqStatusProvider(applianceId)),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('새로 보기'),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            body,
          ],
        ),
      ),
    );
  }

  /// 한 번 묻고, 승인하면 보낸다. 결과는 실행 상태 화면 — 여기서 '바꿨어요'라고 먼저 말하지 않는다.
  /// 끝날 때까지([_sending]) 칩을 잠근다 — 두 번 눌러 명령이 겹치지 않게.
  Future<void> _change(ThinqControl control, String value, String word) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await _askAndSend(control, value, word);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _askAndSend(ThinqControl control, String value, String word) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(control.question(value, word)),
        content: Text('$applianceName 설정을 바꿔요. '
            '바꾼 뒤 새로 보고 바뀌었는지 알려 드려요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('thinq-set-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('바꾸기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      _snack('본체와 연결되면 바꿀 수 있어요.');
      return;
    }
    final execution = ref.read(executionStatusProvider.notifier);
    // 아까 보낸 실행의 접수 답을 기다리는 중 — 또 보내면 늦은 답이 엇갈린다(검토 10/19).
    if (execution.admissionInFlight) {
      _snack(ExecutionStatusNotifier.waitAdmissionNotice);
      return;
    }
    final label = '$applianceName ${control.label} $word';
    // 보내기 전에 '보내는 중'으로 — 답을 기다리는 사이에도 본체는 이미 보냈을 수 있다. 요청 번호를 실어 같은 번호는 본체가
    // 한 번만 보내고, 답을 잃으면 그 번호로 받은 실행을 찾는다(검토 10/19).
    final requestId = execution.beginSubmitting(api: api, label: label, steps: [label]);
    final RpiJobAccepted accepted;
    try {
      accepted = await api.thinqCommand(applianceId, control.action, {control.arg: value},
          clientRequestId: requestId);
    } on RpiApiException catch (e) {
      execution.abandonSubmission(requestId); // 본체가 답했다 — 받지 않았다
      if (!mounted) return;
      final refusal = thinqCommandRefusal(e);
      _snack(refusal ?? kThinqUnknownOutcome);
      if (refusal == null) ref.invalidate(thinqStatusProvider(applianceId));
      return;
    } catch (_) {
      // 시간 초과·연결 끊김·응답 해석 실패 — 허브가 이미 받았을 수 있다. package:http로는 '보내기 전에 닿지 못함'과 '보낸 뒤
      // 응답 없음'을 믿을 만하게 가를 수 없다. 다시 보내지 않고 요청 번호로 본체가 받은 실행을 찾는다(옛 본체는 상태로).
      execution.beginSubmissionUnknown(
          api: api, label: label, steps: [label], requestId: requestId, byRequest: true);
      if (!mounted) return;
      await context.push('/status');
      if (mounted) ref.invalidate(thinqStatusProvider(applianceId));
      return;
    }
    execution.beginHttpJob(
      api: api,
      jobId: accepted.jobId,
      label: label,
      steps: [label],
      requestId: requestId,
    );
    if (!mounted) return;
    await context.push('/status');
    // 돌아오면 바뀐 상태를 다시 읽는다.
    if (mounted) ref.invalidate(thinqStatusProvider(applianceId));
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// 허브가 응답으로 거절한 ThinQ 조작의 문장. null이면 '결과를 모른다'로 다룬다.
///
/// 409·412·422·423은 허브가 보내기 전에 막은 것이다 — 허브가 준 이유를 그대로 보인다
/// (비상 정지 잠금·프로필에 없는 값·다른 작업 실행 중 등). 영어 '실행 중' 문장과 빈 이유만
/// 우리말로 바꾼다. 그 밖의 오류(5xx 등)는 허브가 어디까지 했는지 모르므로 null.
String? thinqCommandRefusal(RpiApiException e) {
  const busy = '다른 일을 하고 있어요. 끝난 뒤 다시 눌러 주세요.';
  switch (e.statusCode) {
    case 401:
      return '연결 비밀번호가 맞지 않아요. 설정에서 봐 주세요.';
    case 409 || 412 || 422 || 423:
      final message = e.message.trim();
      if (message.contains('already in progress')) return busy;
      if (message.isNotEmpty) return message;
      return e.statusCode == 409 ? busy : '지금은 이걸 바꿀 수 없어요. 가전이 켜져 있는지 보고 다시 해 주세요.';
    default:
      return null;
  }
}

/// '오전 7:05 기준' — 읽은 시각(모의면 ' (연습)'). 시각 꼴은 폰 전체와 같다(평가 8차 10/18).
String thinqReadTimeLine(DateTime t, {bool mock = false}) => '${ampmOf(t)} 기준${mock ? ' (연습)' : ''}';

/// 화면 낭독용 시각 — '오전 7시 5분'.
String thinqReadTimeSpoken(DateTime t) => ampmSpoken(t);

const _power = {'POWER_ON': '켜짐', 'POWER_OFF': '꺼짐'};
const _jobMode = {
  'CLEAN': '청정',
  'SLEEP': '수면',
  'AUTO': '자동',
  'SILENT': '조용',
};
// 상태 줄의 운전 방식 — '조용'만 말로 풀어 쓴다(단계 문장은 '조용으로 바꾸기' 그대로).
const _jobModeRow = {
  'CLEAN': '청정',
  'SLEEP': '수면',
  'AUTO': '자동',
  'SILENT': '조용히',
};
// 바람 세기 이름은 고르는 버튼·본체 문장과 같게 '약·중·강'(2차 평가 10/18 — 상태는 약풍, 버튼은 약이었다).
const _wind = {
  'LOW': '약',
  'MID': '중',
  'HIGH': '강',
  'AUTO': '자동',
  'POWER': '파워',
};
// 상태 줄의 바람 세기 — '파워'만 풀어 쓴다(LG 앱 이름은 괄호에).
const _windRow = {
  'LOW': '약',
  'MID': '중',
  'HIGH': '강',
  'AUTO': '자동',
  'POWER': '가장 세게(파워)',
};
// 세탁기 운전 상태(2026-10-18 연습 세탁기). 서버 모의·SDK 상태 이름(runState.currentState) — 모르는 값은 그대로 보인다.
const _washState = {
  'POWER_OFF': '꺼짐',
  'INITIAL': '기다리는 중',
  'DETECTING': '빨래 양 보는 중',
  'RUNNING': '빨래하는 중',
  'RINSING': '헹구는 중',
  'SPINNING': '탈수하는 중',
  'PAUSE': '잠시 멈춤',
  'END': '끝남',
  'ERROR': '문제가 있어요. LG 앱에서 봐 주세요',
};

/// 세탁기 '시작'으로 칠 운전 상태(서버 `WASHER_RUNNING_STATES`와 같은 뜻).
const _washRunning = {'DETECTING', 'RUNNING', 'RINSING', 'SPINNING', 'PREWASH', 'SOAKING'};

const _level = {
  'GOOD': '좋음',
  'NORMAL': '보통',
  'BAD': '나쁨',
  'VERY_BAD': '매우 나쁨',
};

/// 조작 줄 하나 — 허브 동작 이름·인자와 고를 값들, 지금 값.
class ThinqControl {
  const ThinqControl({
    required this.label,
    required this.action,
    required this.arg,
    required this.choices,
    this.current,
  });

  final String label;
  final String action;
  final String arg;
  final List<(String, String)> choices;
  final String? current;

  /// 같은 조작 줄에 지금 값만 채운 것.
  ThinqControl withCurrent(String? current) => ThinqControl(
        label: label,
        action: action,
        arg: arg,
        choices: choices,
        current: current,
      );

  /// 값 → 고를 때 보이는 말(켜기·강·수면). 표에 없으면 null.
  String? wordFor(String value) {
    for (final (v, word) in choices) {
      if (v == value) return word;
    }
    return null;
  }

  /// 확인 질문. 값 이름(약·중·강·자동·청정·수면)은 모두 받침이 있어 '으로'를 붙인다.
  String question(String value, String word) => switch (action) {
        'set_power' => value == 'POWER_OFF' ? '전원을 끌까요?' : '전원을 켤까요?',
        'set_operation' => value == 'STOP' ? '빨래를 잠시 멈출까요?' : '빨래를 시작할까요?',
        'set_job_mode' => '운전 방식을 $word${_ro(word)} 바꿀까요?',
        _ => '$label${_eul(label)} $word${_ro(word)} 바꿀까요?',
      };

  /// 칩의 읽는 이름 — 줄 이름을 붙인다('풍량 자동'·'운전 모드 자동'·'전원 켜기').
  String chipSemantics(String word) => '$label $word';

  /// 루틴 단계 문장(2026-10-15). '전원 켜기', '바람 세기 강으로 바꾸기'.
  String stepPhrase(String word) =>
      action == 'set_power' ? '$label $word' : '$label $word${_ro(word)} 바꾸기';
}

/// '을'/'를' — 끝 글자 받침을 본다('바람 세기를'). 한글이 아니면 '을'.
String _eul(String word) {
  if (word.isEmpty) return '을';
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '을';
  return (code - 0xAC00) % 28 == 0 ? '를' : '을';
}

/// '으로'/'로' — 끝 글자 받침을 본다(없거나 ㄹ이면 '로'). 한글이 아니면 '(으)로'.
String _ro(String word) {
  if (word.isEmpty) return '(으)로';
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '(으)로';
  final jong = (code - 0xAC00) % 28;
  return jong == 0 || jong == 8 ? '로' : '으로';
}

/// 공기청정기 조작 줄 — 지금 값 없이 고를 수 있는 것만. 가전 상세의 조작 줄과
/// 루틴 편집기의 'ThinQ 가전 조작' 단계가 같은 표를 쓴다. 값 목록은 허브 대응표
/// (`rpi/services/thinq/bindings.py`)와 같고, 이 모델 프로필이 허용하지 않는 값은
/// 허브가 보내기 전(루틴은 저장할 때) 거절한다.
const kAirPurifierControls = <ThinqControl>[
  ThinqControl(
    label: '전원',
    action: 'set_power',
    arg: 'power',
    choices: [('POWER_ON', '켜기'), ('POWER_OFF', '끄기')],
  ),
  ThinqControl(
    label: '바람 세기',
    action: 'set_wind_strength',
    arg: 'wind_strength',
    choices: [
      ('LOW', '약'),
      ('MID', '중'),
      ('HIGH', '강'),
      ('AUTO', '자동'),
    ],
  ),
  ThinqControl(
    label: '운전 방식',
    action: 'set_job_mode',
    arg: 'job_mode',
    choices: [('CLEAN', '청정'), ('SLEEP', '수면'), ('AUTO', '자동')],
  ),
];

/// 세탁기 조작 줄(2026-10-18 연습 세탁기) — 서버 대응표 `WASHER_CAPABILITIES`(시작·일시정지)와 같다.
/// 원격 시작이 꺼져 있으면 허브가 보내기 전에 거절한다(그 이유를 그대로 보인다).
const kWasherControls = <ThinqControl>[
  ThinqControl(
    label: '빨래',
    action: 'set_operation',
    arg: 'operation',
    choices: [('START', '시작'), ('STOP', '잠시 멈춤')],
  ),
];

/// 공기청정기·세탁기 상태일 때만 조작 줄을 만든다(표는 [kAirPurifierControls]·[kWasherControls]).
List<ThinqControl> thinqControlsFor(Map<String, dynamic> state) {
  final op = state['operation'];
  final power = op is Map ? op['airPurifierOperationMode']?.toString() : null;
  if (power == null) {
    final run = state['runState'];
    final current = run is Map ? run['currentState']?.toString() : null;
    if (current == null) return const [];
    final picked = _washRunning.contains(current)
        ? 'START'
        : current == 'PAUSE'
            ? 'STOP'
            : null;
    return [for (final c in kWasherControls) c.withCurrent(picked)];
  }
  final flow = state['airFlow'];
  final wind = flow is Map
      ? (flow['windStrengthDetail'] ?? flow['windStrength'])?.toString()
      : null;
  final jobMap = state['airPurifierJobMode'];
  final job = jobMap is Map ? jobMap['currentJobMode']?.toString() : null;
  final current = {
    'set_power': power,
    'set_wind_strength': wind,
    'set_job_mode': job,
  };
  return [
    for (final c in kAirPurifierControls) c.withCurrent(current[c.action]),
  ];
}

/// 공기청정기 전원이 꺼져 있다고 읽혔는가. 전원 칸이 없으면(모름) false.
bool thinqPowerOff(Map<String, dynamic> state) {
  final op = state['operation'];
  return op is Map && op['airPurifierOperationMode']?.toString() == 'POWER_OFF';
}

/// 공기청정기인데 미세먼지 값이 없을 때 이유 한 줄. 값이 있거나 공기청정기가 아니면 null.
///
/// 실가전(10/15): 켠 직후에는 airQualitySensor가 잠시 비어 있다 — 줄을 조용히 빼면 고장처럼 보인다.
/// 꺼져 있을 때는 ThinQ 앱의 공기질 센서 설정에 달렸다(10/15 저녁 확인): '운전 중에만'이면 칸이 없고,
/// '항상'이면 꺼진 채로도 값이 온다 — 값이 오면 전원과 상관없이 값 줄을 보이고 이 줄은 없다.
/// 꺼져 있는데 값이 없으면 꺼져 있을 때도 보는 방법을 함께 말한다.
String? thinqDustNote(Map<String, dynamic> state) {
  final op = state['operation'];
  if (op is! Map || op['airPurifierOperationMode'] == null) return null;
  final sensor = state['airQualitySensor'];
  final hasDust =
      sensor is Map && (sensor['PM2'] != null || sensor['PM10'] != null);
  if (hasDust) return null;
  return thinqPowerOff(state)
      ? kThinqDustOffNote
      : '미세먼지 값이 아직 없어요. 켠 직후에는 잠시 걸려요';
}

/// 꺼져 있고 미세먼지 값이 없을 때 — 이유와, 꺼져 있을 때도 보는 방법.
const kThinqDustOffNote = '전원이 꺼져 있어 미세먼지 값이 오지 않아요. '
    "꺼져 있을 때도 보려면 LG 앱에서 공기질 센서를 '항상'으로 바꿔 주세요.";

/// ThinQ 루틴 단계(동작 + 인자) → 사람 말. 동작 이름(set_wind_strength 같은 것)은
/// 화면에 내지 않는다. 표에 없는 값은 상태 표의 말로, 그래도 모르면 원래 값 그대로
/// 보인다(지어내지 않는다). 모르는 동작이면 'ThinQ 명령(이 앱이 모르는 조작)'.
String thinqStepPhrase(String? action, Map<String, dynamic> args) {
  final control =
      kAirPurifierControls.where((c) => c.action == action).firstOrNull;
  if (control == null) return 'LG 가전 설정 바꾸기';
  final raw = args[control.arg]?.toString();
  if (raw == null) return '${control.label} 바꾸기';
  final word = control.wordFor(raw) ??
      switch (action) {
        'set_wind_strength' => _wind[raw],
        'set_job_mode' => _jobMode[raw],
        _ => _power[raw],
      } ??
      raw;
  return control.stepPhrase(word);
}

/// ThinQ 상태 → (이름, 값) 줄. 아는 칸만 사람 말로 바꾸고, 없는 칸은 줄을 만들지 않는다.
/// 모르는 값은 원래 값 그대로 보인다(지어내지 않는다).
List<(String, String)> thinqStateRows(Map<String, dynamic> state) {
  Object? at(String resource, String prop) {
    final r = state[resource];
    return r is Map ? r[prop] : null;
  }

  String word(Map<String, String> table, Object? v) =>
      table[v?.toString()] ?? v.toString();

  final rows = <(String, String)>[];

  // 전원 — 종류마다 칸 이름이 다르다(airPurifierOperationMode 등).
  final op = state['operation'];
  if (op is Map) {
    final key = op.keys
        .map((k) => k.toString())
        .where((k) => k.endsWith('OperationMode'))
        .firstOrNull;
    if (key != null && op[key] != null) rows.add(('전원', word(_power, op[key])));
  }

  final job = at('airPurifierJobMode', 'currentJobMode');
  if (job != null) rows.add(('운전 방식', word(_jobModeRow, job)));

  final wind = at('airFlow', 'windStrengthDetail') ?? at('airFlow', 'windStrength');
  // 상태 줄은 풀어 쓰고 LG 앱 이름을 괄호에(문구 기준 R10 10/19). 단계 문장('바람 세기 파워로 바꾸기')은 짧은 이름 그대로.
  if (wind != null) rows.add(('바람 세기', word(_windRow, wind)));

  String dust(String value, String level) {
    final v = at('airQualitySensor', value);
    final l = at('airQualitySensor', level);
    if (v == null) return '';
    return l == null ? '$v' : '${word(_level, l)}, $v';
  }

  final pm25 = dust('PM2', 'PM2Level');
  if (pm25.isNotEmpty) rows.add(('초미세먼지', pm25));
  final pm10 = dust('PM10', 'PM10Level');
  if (pm10.isNotEmpty) rows.add(('미세먼지', pm10));

  final filter = at('filterInfo', 'filterRemainPercent');
  if (filter != null) rows.add(('필터 남은 양', '$filter%'));

  // 세탁기(2026-10-18 연습 세탁기) — 운전 상태·남은 시간·원격 시작.
  final wash = at('runState', 'currentState');
  if (wash != null) rows.add(('빨래', word(_washState, wash)));
  final left = thinqRemainText(at('timer', 'remainHour'), at('timer', 'remainMinute'));
  if (left != null) rows.add(('남은 시간', left));
  final remote = at('remoteControlEnable', 'remoteControlEnabled');
  if (remote is bool) rows.add(('휴대폰으로 시작', remote ? '켜져 있어요' : '꺼져 있어요'));

  return rows;
}

/// 세탁기 남은 시간 — '45분'·'1시간 5분'. 둘 다 없으면 null(지어내지 않는다).
String? thinqRemainText(Object? hour, Object? minute) {
  final h = hour is num ? hour.toInt() : null;
  final m = minute is num ? minute.toInt() : null;
  if (h == null && m == null) return null;
  final hh = h ?? 0;
  final mm = m ?? 0;
  if (hh <= 0) return '$mm분';
  return mm <= 0 ? '$hh시간' : '$hh시간 $mm분';
}
