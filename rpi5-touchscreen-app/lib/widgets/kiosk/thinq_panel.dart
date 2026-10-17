import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/thinq.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'estop_banner.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_text.dart';

/// 가전 등급 색(2026-10-16) — 좋음 초록 · 보통 중립 · 나쁨 앰버 · 매우 나쁨 빨강. 글자(등급 말)를 늘 함께 쓴다(색만으로 말하지 않는다).
Color airGradeColor(String? grade) => switch (grade) {
      'GOOD' => KioskColors.confirmed,
      'BAD' => KioskColors.warning,
      'VERY_BAD' => KioskColors.danger,
      _ => Colors.white,
    };

/// 비상 멈춤이 걸려 있을 때 조작 칸 아래 문장.
const kThinqEstopNote = '비상 버튼이 눌려 있어 지금은 바꿀 수 없어요';

/// 전원이 꺼져 있을 때 풍량 칸 아래 문장(폰과 같은 뜻).
const kThinqPowerOffNote = '전원을 켠 뒤 바꿀 수 있어요';

/// 연습(모의) ThinQ 표시.
const kThinqPracticeText = '연습이에요. 실제 가전은 그대로예요';

/// ThinQ 가전 상세(2026-10-16, 사용자 요청) — 왼쪽 지금 상태, 오른쪽 큰 조작 단추.
///
/// - 상태는 **열 때 한 번**과 '다시 읽기'에서만 읽는다(GET /thinq/status — 클라우드 호출). 못 읽으면 이유만 말하고
///   값·조작을 내걸지 않는다(지금 값을 모른다). 읽은 시각을 'HH:MM에 읽음'로 적는다.
/// - 조작은 공기청정기의 전원·풍량만(서버 대응표 값). 누르면 곧바로 보내지 않고 한 번 묻는다 — '바꾸기'를 눌러야
///   POST /thinq/command. 접수되면 [onAccepted]가 실행 화면으로 넘긴다(결과 문장은 실행·결과 화면이 서버 확인 수준대로).
/// - 전원이 꺼져 있으면 풍량 단추를 잠그고 '전원을 켠 뒤 바꿀 수 있어요'. 비상 멈춤 띠가 보이면 모든 조작을 잠근다.
/// - 큰 글씨에서는 두 칸을 세로 한 줄로 쌓는다(§1-8) — 글자를 줄이지 않는다.
class KioskThinqPanel extends StatefulWidget {
  const KioskThinqPanel({
    super.key,
    required this.appliance,
    required this.readStatus,
    required this.sendCommand,
    required this.onAccepted,
  });

  final ApplianceMap appliance;

  /// GET /thinq/status/{id}. null이면 허브가 없어 읽지 못한다.
  final Future<KioskThinqStatus> Function()? readStatus;

  /// POST /thinq/command.
  final Future<KioskJobAccepted> Function(String action, Map<String, Object> args)? sendCommand;

  /// 접수됨 — job_id와 실행 화면 제목.
  final void Function(String jobId, String label) onAccepted;

  @override
  State<KioskThinqPanel> createState() => _KioskThinqPanelState();
}

class _PendingChange {
  const _PendingChange(this.control, this.value, this.word);
  final ThinqControl control;
  final String value;
  final String word;
}

class _KioskThinqPanelState extends State<KioskThinqPanel> {
  KioskThinqStatus? _status;
  bool _loading = false;
  bool _sending = false;
  _PendingChange? _pending;
  String? _message;
  int _readSeq = 0;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final reader = widget.readStatus;
    final seq = ++_readSeq;
    if (reader == null) {
      setState(() => _status = const KioskThinqStatus(failure: '본체에 연결되지 않았어요'));
      return;
    }
    setState(() => _loading = true);
    KioskThinqStatus status;
    try {
      status = await reader();
    } catch (_) {
      status = const KioskThinqStatus(failure: '본체에 연결되지 않았어요');
    }
    if (!mounted || seq != _readSeq) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _send(_PendingChange change) async {
    final send = widget.sendCommand;
    setState(() {
      _pending = null;
      _message = null;
    });
    if (send == null) {
      setState(() => _message = '본체에 연결되면 바꿀 수 있어요.');
      return;
    }
    setState(() => _sending = true);
    final label = change.control.doneLabel(widget.appliance.name, change.word);
    try {
      final accepted = await send(change.control.action, {change.control.arg: change.value});
      if (!mounted) return;
      setState(() => _sending = false);
      widget.onAccepted(accepted.jobId, label);
    } on KioskApiException catch (e) {
      if (!mounted) return;
      final refusal = thinqCommandRefusal(e.statusCode, e.detail);
      setState(() {
        _sending = false;
        _message = refusal ?? kThinqUnknownOutcome;
      });
      if (refusal == null) unawaited(_read());
    } catch (_) {
      // 시간 초과·끊김 — 허브가 이미 받았을 수 있다. 결과를 모른다고 말하고 다시 읽는다.
      if (!mounted) return;
      setState(() {
        _sending = false;
        _message = kThinqUnknownOutcome;
      });
      unawaited(_read());
    }
  }

  @override
  Widget build(BuildContext context) {
    final large = KioskLayout.isLarge(context);
    final estop = KioskEstopScope.shownOf(context);
    final status = _status;
    final state = _loading ? null : status;
    final left = _StateCard(
      status: state,
      loading: _loading || status == null,
      onReread: _loading || _sending ? null : _read,
    );
    final right = _Controls(
      status: state,
      estop: estop,
      busy: _loading || _sending,
      sending: _sending,
      message: _message,
      onPick: (control, value, word) =>
          setState(() => _pending = _PendingChange(control, value, word)),
    );
    final pending = _pending;
    return Stack(
      children: [
        Positioned.fill(
          child: large
              // 넘치면 스크롤 막대가 늘 보인다 — 아래에 조작 단추가 더 있다는 것을 알 수 있게.
              ? KioskScrollArea(
                  key: const ValueKey('thinq-panel-scroll'),
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    // 조작을 먼저 — 큰 글씨에서 켜기·끄기가 스크롤 아래로 밀렸다(UI 평가 10/17). 상태는 그 아래.
                    children: [right, const SizedBox(height: 16), left],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: KioskScrollArea(child: left)),
                      const SizedBox(width: 20),
                      Expanded(flex: 6, child: KioskScrollArea(child: right)),
                    ],
                  ),
                ),
        ),
        if (pending != null)
          Positioned.fill(
            child: _ChangeConfirm(
              question: pending.control.question(widget.appliance.name, pending.value, pending.word),
              // 비상 멈춤이 걸리면 묻던 것도 보내지 않는다.
              onConfirm: estop ? null : () => _send(pending),
              onCancel: () => setState(() => _pending = null),
            ),
          ),
      ],
    );
  }
}

/// 왼쪽 — 지금 상태. 공기는 '공기 나빠요' 한 줄 + 색이고, 먼지 숫자·등급 출처는 '자세히'를 눌러야 보인다(2차 평가 10/18).
class _StateCard extends StatefulWidget {
  const _StateCard({required this.status, required this.loading, required this.onReread});

  final KioskThinqStatus? status;
  final bool loading;
  final VoidCallback? onReread;

  @override
  State<_StateCard> createState() => _StateCardState();
}

class _StateCardState extends State<_StateCard> {
  bool _airOpen = false;

  static const _dustLabels = {'초미세먼지', '미세먼지'};

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final loading = widget.loading;
    final onReread = widget.onReread;
    final List<Widget> body;
    if (loading || s == null) {
      body = const [
        KioskText('지금 상태를 보는 중…',
            textKey: ValueKey('thinq-reading'),
            style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
      ];
    } else if (!s.ok) {
      body = [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: KioskColors.warning, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: KioskText('지금 상태를 못 봤어요. ${s.failure}',
                  textKey: const ValueKey('thinq-read-failed'),
                  style: const TextStyle(fontSize: KioskType.body, color: Colors.white, height: 1.3)),
            ),
          ],
        ),
      ];
    } else {
      final map = s.stateMap;
      final all = thinqStateRows(map);
      final rows = all.where((r) => !_dustLabels.contains(r.label)).toList();
      final dust = all.where((r) => _dustLabels.contains(r.label)).toList();
      final sensor = map['airQualitySensor'];
      final total = sensor is Map ? sensor['totalPollutionLevel']?.toString() : null;
      final grade = [
        total,
        if (sensor is Map) sensor['PM2Level']?.toString(),
        if (sensor is Map) sensor['PM10Level']?.toString(),
      ].whereType<String>().where(kAirGradeWords.containsKey).firstOrNull;
      final dustNote = thinqDustNote(map);
      body = [
        if (all.isEmpty)
          const KioskText('보여 줄 상태가 없어요',
              style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted))
        else
          for (final row in rows) _StateRowView(row: row),
        if (dust.isNotEmpty) ...[
          const SizedBox(height: KioskSpace.xs),
          Row(children: [
            Icon(Icons.air, size: 26, color: airGradeColor(grade)),
            const SizedBox(width: KioskSpace.xs),
            Expanded(
              child: KioskText(grade == null ? '공기' : airSentence(grade),
                  textKey: const ValueKey('thinq-air-summary'),
                  style: TextStyle(
                      fontSize: KioskType.body,
                      fontWeight: FontWeight.w800,
                      color: grade == null ? Colors.white : airGradeColor(grade))),
            ),
            OutlinedButton(
              key: const ValueKey('thinq-air-more'),
              onPressed: () => setState(() => _airOpen = !_airOpen),
              style: KioskButtons.secondary(foreground: Colors.white, border: KioskColors.border)
                  .copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.sm)),
              ),
              child: Text(_airOpen ? '접기' : '자세히',
                  style: const TextStyle(fontSize: KioskType.caption)),
            ),
          ]),
          if (_airOpen) ...[
            for (final row in dust) _StateRowView(row: row),
            if (total != null && kAirGradeWords.containsKey(total))
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: KioskText('종합은 가전이 매긴 등급이에요',
                    textKey: ValueKey('thinq-air-total-note'),
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
              ),
          ],
        ],
        if (dustNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: KioskText(dustNote,
                textKey: const ValueKey('thinq-dust-note'),
                style: const TextStyle(fontSize: KioskType.caption, color: KioskColors.muted, height: 1.3)),
          ),
        if (s.readAt != null) ...[
          const SizedBox(height: 8),
          KioskText(thinqReadTimeLine(s.readAt!, mock: s.mock),
              textKey: const ValueKey('thinq-read-time'),
              style: const TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
        ],
      ];
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 16),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                // '(연습)'은 아래 읽은 시각 줄과 위 연습 칸이 말한다 — 제목에 붙이면 '다시 읽기'에 닿았다(UI 평가 3차 10/17).
                child: Text('지금 상태',
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                        fontSize: KioskType.body, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const ValueKey('thinq-reread'),
                onPressed: onReread,
                style: KioskButtons.secondary(foreground: Colors.white, border: KioskColors.border)
                    .copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14))),
                icon: const Icon(Icons.refresh, size: 22),
                label: const Text('새로 보기',
                    maxLines: 1, softWrap: false, style: TextStyle(fontSize: KioskType.caption)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...body,
        ],
      ),
    );
  }
}

class _StateRowView extends StatelessWidget {
  const _StateRowView({required this.row});
  final ThinqStateRow row;

  @override
  Widget build(BuildContext context) {
    final grade = row.grade;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          KioskText(row.label, style: const TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (grade != null) ...[
                Icon(Icons.circle, size: 14, color: airGradeColor(grade)),
                const SizedBox(width: 6),
              ],
              KioskText(row.value,
                  textKey: ValueKey('thinq-row-${row.label}'),
                  style: TextStyle(
                      fontSize: KioskType.body,
                      fontWeight: FontWeight.w700,
                      color: grade != null ? airGradeColor(grade) : Colors.white)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PracticeChip extends StatelessWidget {
  const _PracticeChip();

  @override
  Widget build(BuildContext context) => const Row(
        key: ValueKey('thinq-practice'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_outlined, color: KioskColors.practice, size: 22),
          SizedBox(width: 8),
          Flexible(
            child: KioskText(kThinqPracticeText,
                style: TextStyle(fontSize: KioskType.caption, color: Colors.white, height: 1.3)),
          ),
        ],
      );
}

/// 오른쪽 — 큰 조작 단추(공기청정기 전원·풍량).
class _Controls extends StatelessWidget {
  const _Controls({
    required this.status,
    required this.estop,
    required this.busy,
    required this.sending,
    required this.message,
    required this.onPick,
  });

  final KioskThinqStatus? status;
  final bool estop;
  final bool busy;
  final bool sending;
  final String? message;
  final void Function(ThinqControl control, String value, String word) onPick;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final children = <Widget>[];
    if (s == null) {
      // 읽는 중 — 조작 칸은 아직 그리지 않는다.
    } else if (!s.ok) {
      children.add(const KioskText('지금 상태를 본 뒤 바꿀 수 있어요. 왼쪽의 새로 보기를 눌러 주세요.',
          textKey: ValueKey('thinq-controls-unknown'),
          style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted, height: 1.3)));
    } else {
      final map = s.stateMap;
      final controls = thinqControlsFor(map);
      final powerOff = thinqPowerOff(map);
      // 연습(모의)이면 조작 칸 맨 위에 — 누르는 단추가 실제 가전에 가지 않는다는 것을 조작 바로 옆에서 말한다.
      if (s.mock) {
        children.add(const Padding(padding: EdgeInsets.only(bottom: 10), child: _PracticeChip()));
      }
      if (controls.isEmpty) {
        children.add(const KioskText('이 가전은 휴대폰 SimpleLay 앱에서 바꿀 수 있어요.',
            textKey: ValueKey('thinq-controls-phone'),
            style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted, height: 1.3)));
      }
      for (final control in controls) {
        final blockedByPower = powerOff && !control.isPower;
        final enabled = !estop && !busy && !blockedByPower;
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KioskText(control.label,
                  style: const TextStyle(
                      fontSize: KioskType.body, fontWeight: FontWeight.w700, color: Colors.white)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final (i, (value, word)) in control.choices.indexed) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _ChoiceButton(
                        key: ValueKey('thinq-set-${control.action}-$value'),
                        word: word,
                        semantics: '${control.label} $word',
                        current: control.current == value,
                        onTap: enabled && control.current != value
                            ? () => onPick(control, value, word)
                            : null,
                        enabled: enabled,
                      ),
                    ),
                  ],
                ],
              ),
              if (blockedByPower) ...[
                const SizedBox(height: 6),
                const KioskText(kThinqPowerOffNote,
                    textKey: ValueKey('thinq-power-off-note'),
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
              ],
            ],
          ),
        ));
      }
      if (controls.isNotEmpty && estop) {
        children.add(const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: KioskColors.danger, size: 26),
            SizedBox(width: 8),
            Expanded(
              child: KioskText(kThinqEstopNote,
                  textKey: ValueKey('thinq-estop-note'),
                  style: TextStyle(fontSize: KioskType.body, color: Colors.white, height: 1.3)),
            ),
          ],
        ));
      }
    }
    if (sending) {
      children.add(const Padding(
        padding: EdgeInsets.only(top: 6),
        child: KioskText('보내는 중…',
            textKey: ValueKey('thinq-sending'),
            style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
      ));
    }
    final msg = message;
    if (msg != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, color: KioskColors.warning, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: KioskText(msg,
                  textKey: const ValueKey('thinq-message'),
                  style: const TextStyle(fontSize: KioskType.body, color: Colors.white, height: 1.3)),
            ),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// 값 단추 하나. 지금 값은 흰 굵은 테두리 + ✓(색만으로 말하지 않는다), 다른 값은 보조(테두리) 단추.
/// 높이는 주 단추와 같다(KioskSizes.primaryButton — 1920x1080에서 약 148px).
class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    super.key,
    required this.word,
    required this.semantics,
    required this.current,
    required this.onTap,
    required this.enabled,
  });

  final String word;
  final String semantics;
  final bool current;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fg = enabled || current ? Colors.white : Colors.white.withValues(alpha: 0.35);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: current,
      label: current ? '$semantics, 지금 값' : semantics,
      excludeSemantics: true,
      child: Material(
        color: current ? KioskColors.surface2 : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
          side: BorderSide(
              color: current ? Colors.white : (enabled ? KioskColors.border : KioskColors.border.withValues(alpha: 0.1)),
              width: current ? 3 : 2),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: KioskSizes.primaryButton),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (current) ...[
                        Icon(Icons.check, color: fg, size: 26),
                        const SizedBox(width: 4),
                      ],
                      Text(word,
                          style: TextStyle(
                              fontSize: KioskType.status,
                              fontWeight: current ? FontWeight.w800 : FontWeight.w600,
                              color: fg)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 바꾸기 전 한 번 묻는다 — '바꾸기'를 눌러야 보낸다.
class _ChangeConfirm extends StatelessWidget {
  const _ChangeConfirm({required this.question, required this.onConfirm, required this.onCancel});

  final String question;
  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              key: const ValueKey('thinq-confirm'),
              width: 520,
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: KioskColors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KioskText(question,
                      textKey: const ValueKey('thinq-confirm-question'),
                      style: const TextStyle(
                          fontSize: KioskType.status, fontWeight: FontWeight.w700, color: Colors.white, height: 1.25)),
                  const SizedBox(height: 10),
                  const KioskText('LG 가전으로 보내요. 바뀌었는지는 보낸 뒤 다시 봐요.',
                      style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted, height: 1.3)),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: OutlinedButton(
                          key: const ValueKey('thinq-confirm-cancel'),
                          onPressed: onCancel,
                          style: KioskButtons.secondary(foreground: Colors.white, border: KioskColors.border)
                              .copyWith(minimumSize: const WidgetStatePropertyAll(Size(0, KioskSizes.primaryButton))),
                          child: const Text('취소', style: TextStyle(fontSize: KioskType.body)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: ElevatedButton(
                          key: const ValueKey('thinq-confirm-ok'),
                          onPressed: onConfirm,
                          style: KioskButtons.primary(
                              background: KioskColors.primary, foreground: KioskColors.onAccent),
                          child: const Text('바꾸기',
                              style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
