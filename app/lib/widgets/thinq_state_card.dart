import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../providers/execution_status_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// ThinQ 가전 상세의 '지금 상태' 카드(2026-10-15, 사용자 요청 동결 예외).
///
/// 못 읽었으면 이유를 말하고 값을 지어내지 않는다. 읽은 시각을 같이 적는다 —
/// ThinQ 값은 그 시각의 것이지 지금 이 순간의 보장이 아니다.
///
/// 공기청정기는 전원·풍량·운전 모드를 여기서 바꾼다(같은 날 사용자 요청). **누르면
/// 곧바로 보내지 않고 한 번 묻는다** — 승인하면 POST /thinq/command, 결과는 실행
/// 상태 화면이 확인 단계와 함께 말하고, 돌아오면 상태를 다시 읽는다. 상태를 못 읽었을
/// 때는 지금 값을 모르므로 조작 줄을 내걸지 않는다.
class ThinqStateCard extends ConsumerWidget {
  const ThinqStateCard({
    super.key,
    required this.applianceId,
    this.applianceName = '가전',
  });

  final String applianceId;
  final String applianceName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(thinqStatusProvider(applianceId));
    final status = async.valueOrNull;
    final loading = async.isLoading;

    Widget body;
    if (status == null) {
      body = Text('ThinQ에서 읽는 중…',
          style: TextStyle(fontSize: 15, color: context.appMuted));
    } else if (!status.ok) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: context.appWarning),
          const SizedBox(width: 6),
          Expanded(
            child: Text('지금 상태를 읽지 못했어요 — ${status.failure}',
                style: TextStyle(fontSize: 15, color: context.appWarning)),
          ),
        ],
      );
    } else {
      final rows = thinqStateRows(status.state);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty)
            Text('표시할 수 있는 상태 값이 없어요',
                style: TextStyle(fontSize: 15, color: context.appMuted))
          else
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(label,
                          style: TextStyle(fontSize: 15, color: context.appMuted)),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(value,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
          if (status.readAt != null) ...[
            const SizedBox(height: 6),
            Text(
              'ThinQ에서 ${_hms(status.readAt!)}에 읽었어요'
              '${status.executionMode == 'mock' ? ' (모의)' : ''}',
              style: TextStyle(fontSize: 13, color: context.appMuted),
            ),
          ],
          for (final control in thinqControlsFor(status.state)) ...[
            const SizedBox(height: 14),
            Text(control.label,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, word) in control.choices)
                  ChoiceChip(
                    key: Key('thinq-set-${control.action}-$value'),
                    label: Text(word, style: const TextStyle(fontSize: 16)),
                    selected: control.current == value,
                    // 지금 값도 흐리게 만들지 않는다(꺼진 버튼처럼 보이지 않게) — 눌러도 아무것도 안 한다.
                    onSelected: loading
                        ? null
                        : (_) {
                            if (control.current == value) return;
                            _change(context, ref, control, value, word);
                          },
                  ),
              ],
            ),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
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
                    status?.executionMode == 'mock' ? '지금 상태 (모의)' : '지금 상태',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  key: const Key('thinq-status-refresh'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: loading
                      ? null
                      : () => ref.invalidate(thinqStatusProvider(applianceId)),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('다시 읽기'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            body,
          ],
        ),
      ),
    );
  }

  /// 한 번 묻고, 승인하면 보낸다. 결과는 실행 상태 화면 — 여기서 '바꿨어요'라고 먼저 말하지 않는다.
  Future<void> _change(BuildContext context, WidgetRef ref, ThinqControl control,
      String value, String word) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(control.question(value, word)),
        content: Text('허브가 ThinQ로 $applianceName에 보내요. '
            '바뀌었는지는 상태를 다시 읽어 확인해요.'),
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
    if (ok != true || !context.mounted) return;
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      _snack(context, '허브에 연결되면 바꿀 수 있어요.');
      return;
    }
    try {
      final accepted =
          await api.thinqCommand(applianceId, control.action, {control.arg: value});
      final label = '$applianceName ${control.label} $word';
      ref.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: accepted.jobId,
            label: label,
            steps: [label],
          );
      if (!context.mounted) return;
      await context.push('/status');
      // 돌아오면 바뀐 상태를 다시 읽는다.
      ref.invalidate(thinqStatusProvider(applianceId));
    } on RpiApiException catch (e) {
      if (!context.mounted) return;
      _snack(
        context,
        switch (e.statusCode) {
          409 => '다른 작업이 실행 중이에요. 끝난 뒤 다시 눌러 주세요.',
          412 || 422 => e.message,
          _ => '바꾸기를 보내지 못했어요. 연결을 확인해 주세요.',
        },
      );
    } catch (_) {
      if (context.mounted) _snack(context, '바꾸기를 보내지 못했어요. 연결을 확인해 주세요.');
    }
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _hms(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

const _power = {'POWER_ON': '켜짐', 'POWER_OFF': '꺼짐'};
const _jobMode = {
  'CLEAN': '청정',
  'SLEEP': '수면',
  'AUTO': '자동',
  'SILENT': '조용',
};
const _wind = {
  'LOW': '약풍',
  'MID': '중풍',
  'HIGH': '강풍',
  'AUTO': '자동',
  'POWER': '파워',
};
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

  /// 값 → 고를 때 보이는 말(켜기·강풍·수면). 표에 없으면 null.
  String? wordFor(String value) {
    for (final (v, word) in choices) {
      if (v == value) return word;
    }
    return null;
  }

  /// 확인 질문. 값 이름(약풍·강풍·자동·청정·수면)은 모두 받침이 있어 '으로'를 붙인다.
  String question(String value, String word) => switch (action) {
        'set_power' => value == 'POWER_OFF' ? '전원을 끌까요?' : '전원을 켤까요?',
        'set_job_mode' => '운전 모드를 $word으로 바꿀까요?',
        _ => '$label을 $word으로 바꿀까요?',
      };

  /// 루틴 단계 문장(2026-10-15). '전원 켜기', '풍량 강풍으로 바꾸기'.
  String stepPhrase(String word) =>
      action == 'set_power' ? '$label $word' : '$label $word${_ro(word)} 바꾸기';
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
    label: '풍량',
    action: 'set_wind_strength',
    arg: 'wind_strength',
    choices: [
      ('LOW', '약풍'),
      ('MID', '중풍'),
      ('HIGH', '강풍'),
      ('AUTO', '자동'),
    ],
  ),
  ThinqControl(
    label: '운전 모드',
    action: 'set_job_mode',
    arg: 'job_mode',
    choices: [('CLEAN', '청정'), ('SLEEP', '수면'), ('AUTO', '자동')],
  ),
];

/// 공기청정기 상태일 때만 조작 줄을 만든다(표는 [kAirPurifierControls]).
List<ThinqControl> thinqControlsFor(Map<String, dynamic> state) {
  final op = state['operation'];
  final power = op is Map ? op['airPurifierOperationMode']?.toString() : null;
  if (power == null) return const [];
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

/// ThinQ 루틴 단계(동작 + 인자) → 사람 말. 동작 이름(set_wind_strength 같은 것)은
/// 화면에 내지 않는다. 표에 없는 값은 상태 표의 말로, 그래도 모르면 원래 값 그대로
/// 보인다(지어내지 않는다). 모르는 동작이면 'ThinQ 명령(이 앱이 모르는 조작)'.
String thinqStepPhrase(String? action, Map<String, dynamic> args) {
  final control =
      kAirPurifierControls.where((c) => c.action == action).firstOrNull;
  if (control == null) return 'ThinQ 명령(이 앱이 모르는 조작)';
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
  if (job != null) rows.add(('운전 모드', word(_jobMode, job)));

  final wind = at('airFlow', 'windStrengthDetail') ?? at('airFlow', 'windStrength');
  if (wind != null) rows.add(('풍량', word(_wind, wind)));

  String dust(String value, String level) {
    final v = at('airQualitySensor', value);
    final l = at('airQualitySensor', level);
    if (v == null) return '';
    return l == null ? '$v' : '$v · ${word(_level, l)}';
  }

  final pm25 = dust('PM2', 'PM2Level');
  if (pm25.isNotEmpty) rows.add(('초미세먼지(PM2.5)', pm25));
  final pm10 = dust('PM10', 'PM10Level');
  if (pm10.isNotEmpty) rows.add(('미세먼지(PM10)', pm10));

  final filter = at('filterInfo', 'filterRemainPercent');
  if (filter != null) rows.add(('필터 남은 양', '$filter%'));

  return rows;
}
