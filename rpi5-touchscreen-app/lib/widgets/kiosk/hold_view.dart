import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/josa.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_scroll_area.dart';
import 'practice_band.dart';

/// 동작 중 화면(UI 확정 2026-09-30 §3-3) — 버튼을 다 누른 뒤 가전이 돌아가는 동안.
///
/// 작은 팔(누름 장치)은 정지 버튼 위에서 기다린다(`/status.hold_state = hovering_stop`).
/// 큰 "정지"는 `/stop`을 보내고, 서버는 그 정지를 **정지 버튼 누름**으로 전달한다.
/// 판정(정지됨·미확인·구동부 이상)은 RPi4가 하고 서버가 옮긴다 — 화면은 지어내지
/// 않는다. 특히:
/// - "가전이 멈췄어요"는 `hold_stop_outcome = stopped`(전력 하강 확인)일 때만.
/// - 남은 시간은 서버가 주지 않는다(전력 추정 미구현). 대신 시작한 뒤 흐른 시간을
///   값을 만들지 않고 남은 시간을 모른다고 안내한다.
/// - 연습용(mock) 대기는 맨 위 띠로 연습이라고 적는다(2026-10-15).
class KioskHoldView extends StatelessWidget {
  const KioskHoldView({
    super.key,
    required this.appliance,
    required this.holdState,
    this.stopOutcome,
    this.detail,
    this.stopButton,
    this.executionMode,
    required this.elapsed,
    this.buttonsPressed,
    this.operationConfirmed,
    this.operationSource,
    this.stopRequested = false,
    this.stopFailed = false,
    required this.onStop,
    this.onClose,
    this.estopTitle,
  });

  /// 대기 중인 가전(서버 목록에서 찾은 것). 모르면 null — 이름을 지어내지 않는다.
  final ApplianceMap? appliance;

  /// hovering_stop | stopping | parking | parked | fault
  final String holdState;

  /// stopped | requested_unconfirmed | drive_fault | null
  final String? stopOutcome;
  final String? detail;

  /// 정지 버튼 라벨.
  final String? stopButton;

  /// mock | real | unknown
  final String? executionMode;
  final Duration elapsed;

  /// 마지막 실행에서 누름이 보고된 버튼 수. 모르면 null.
  final int? buttonsPressed;
  final bool? operationConfirmed;
  final String? operationSource;

  /// 정지를 보냈고 아직 대기 상태가 바뀌지 않았다.
  final bool stopRequested;

  /// 정지 요청조차 보내지 못했다.
  final bool stopFailed;
  final VoidCallback onStop;

  /// 사람이 닫아야 끝나는 결과(미확인·이상)일 때만 있다.
  final VoidCallback? onClose;

  /// 비상 멈춤이 걸려 있으면 그 제목(위 띠와 같은 말, 2026-10-15). 걸려 있는 동안에는
  /// '돌아가고 있어요' 같은 제목을 쓰지 않는다 — 위 띠와 아래 제목이 서로 다른 말을 하지 않게.
  final String? estopTitle;

  bool get _fault => holdState == 'fault' || stopOutcome == 'drive_fault';

  bool get _mock => executionMode == 'mock';

  String get _name => appliance?.name ?? '가전';

  /// 가전 동작을 실제 전력으로 확인했나(출처 real, 연습 아님).
  bool get _operationReal =>
      operationConfirmed == true && operationSource == 'real' && !_mock;

  // 주어를 밝힌다(2026-10-15 문구 개선 §2-2) — 정지 대기·이동은 **작은 팔**, 돌아가는 것은 **가전**.
  // 가전이 돈다고는 전력으로 확인했을 때만 말한다.
  (String, Color) get _headline {
    if (estopTitle case final t?) {
      return ('$t · 가전이 멈췄는지는 직접 봐 주세요', KioskColors.warning);
    }
    if (_fault) return ('작은 팔 장치에 문제가 생겼어요', KioskColors.danger);
    if (stopOutcome == 'requested_unconfirmed') {
      return ('작은 팔이 대신 눌렀지만 멈췄는지 확인하지 못했어요', KioskColors.warning);
    }
    return switch (holdState) {
      'stopping' => (
          _mock ? '정지 버튼을 짚고 있어요' : '작은 팔이 정지 버튼을 누르고 있어요',
          Colors.white
        ),
      'parking' => ('작은 팔이 제자리로 돌아가고 있어요', Colors.white),
      'parked' => ('작은 팔이 제자리로 돌아갔어요', Colors.white),
      _ => _mock
          ? ('$_name 연습 중', Colors.white)
          : _operationReal
              ? ('${withSubject(_name)} 돌아가고 있어요', Colors.white)
              : ('작은 팔이 $_name 옆에서 기다리고 있어요', Colors.white),
    };
  }

  String get _operationLine {
    final ok = operationConfirmed;
    if (ok == null) return '가전이 움직이는지는 확인하지 못했어요';
    if (!ok) return '전력으로 가전 동작을 확인하지 못했어요';
    // 외부 평가 2026-10-13 M5: 출처가 real일 때만 확인이라고 말한다. 모의 실행·모의 입력은 연습 값,
    // 출처를 모르면 단정하지 않는다.
    if (_mock || operationSource == 'mock') {
      return '연습용 값이에요 — 실제로 잰 값이 아니에요';
    }
    return operationSource == 'real'
        ? '전력으로 가전 동작을 확인했어요'
        : '가전이 켜졌는지는 직접 봐 주세요';
  }

  @override
  Widget build(BuildContext context) {
    final (headline, headColor) = _headline;
    final waiting = holdState == 'hovering_stop' || holdState == 'stopping';
    final unconfirmed = stopOutcome == 'requested_unconfirmed';
    final cancel = stopButton;
    final lines = <(IconData, String, Color)>[
      if (waiting && buttonsPressed != null && buttonsPressed! > 0)
        (
          Icons.check_circle_outline,
          _mock ? '연습으로 $buttonsPressed개를 짚었어요' : '버튼 $buttonsPressed개를 눌렀어요',
          KioskColors.muted
        ),
      // 정지 대기 안내는 흰색 — 주의색은 확인 못 함에만 쓴다(2026-10-15).
      if (holdState == 'hovering_stop')
        (
          Icons.my_location,
          _mock
              ? (cancel == null
                  ? '정지를 누르면 정지 버튼을 짚는 연습을 해요'
                  : "정지를 누르면 '$cancel' 버튼을 짚는 연습을 해요")
              : (cancel == null
                  ? '정지를 누르면 작은 팔이 가전의 정지 버튼을 대신 눌러요'
                  : "정지를 누르면 작은 팔이 '$cancel' 버튼을 대신 눌러요"),
          KioskColors.muted
        ),
      if (unconfirmed && holdState == 'parked')
        (Icons.check, '작은 팔이 제자리로 돌아갔어요', KioskColors.muted),
      if (detail != null && detail!.isNotEmpty && stopOutcome != 'stopped')
        (
          _fault ? Icons.power_settings_new : Icons.info_outline,
          detail!,
          _fault ? KioskColors.danger : KioskColors.muted
        ),
    ];

    // 정지가 어떻게 됐는지(보냄·못 보냄·멈춤·확인 필요)는 정지 버튼과 한 묶음이다 —
    // 큰 글씨에서도 스크롤 없이 보이도록 오른쪽 정지 버튼 바로 위에 고정한다(10/5 수리).
    // 나머지 안내 줄은 왼쪽에서 스크롤돼도 된다.
    final stopLines = <(IconData, String, Color)>[
      // 가전이 멈췄다는 말은 RPi4가 전력 하강으로 확인한 때만(hold_stop_outcome == stopped).
      if (stopOutcome == 'stopped')
        (Icons.check, '${withSubject(_name)} 멈춘 것을 전력으로 확인했어요', Colors.white),
      // 멈췄는지 모르면 가장 큰 글자가 할 일 한 가지다(원칙 0-3).
      if (unconfirmed)
        (
          Icons.touch_app_outlined,
          cancel == null
              ? '지금 $_name의 정지·취소 버튼을 직접 눌러 주세요'
              : "지금 $_name의 '$cancel' 버튼을 직접 눌러 주세요",
          KioskColors.warning
        ),
      // 마지막 시도가 실패했으면 앞선 "보냈어요"는 지운다 — 지금 할 일은 다시 누르기다.
      if (stopRequested && !stopFailed && holdState == 'hovering_stop')
        (Icons.send, '멈추라고 보냈어요', Colors.white),
      if (stopFailed)
        (
          Icons.error_outline,
          '정지 요청을 보내지 못했어요. 다시 누르거나 가전 전원을 직접 꺼 주세요.',
          KioskColors.danger
        ),
    ];

    // 실행 근거(연습용 값인지·실제 확인인지)는 안전 문장이다 — 스크롤 없이 늘
    // 보이도록 스크롤 영역 밖, 제목 바로 아래에 고정한다(10/5 수리).
    final provenance = <(IconData, String, Color)>[
      if (waiting)
        (
          Icons.bolt,
          _operationLine,
          _operationReal || _mock || operationSource == 'mock'
              ? KioskColors.muted
              : KioskColors.warning
        ),
    ];

    // 확인 못 함이면 단추 이름이 할 일을 말한다 — 자리·크기·색은 그대로(원칙 0-4).
    final stopLabel = unconfirmed ? '다시 정지 시도' : '정지';

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(36, 18, 28, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 왼쪽: 무엇이 · 얼마나 · 무엇을 근거로 ───────────────────
          Expanded(
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(appliance?.icon ?? Icons.widgets_outlined,
                        size: 30, color: KioskColors.primary),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        headline,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: headColor,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                if (provenance.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _Lines(lines: provenance),
                ] else
                  const SizedBox(height: 18),
                // 넘치면 스크롤 막대가 보인다(2026-10-15 B9) — 큰 글씨에서 안내가 잘린 채 끝나 보였다.
                Expanded(
                  child: KioskScrollArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (waiting) ...[
                          const Text('남은 시간을 아직 알 수 없어요',
                              style: TextStyle(
                                  fontSize: 26,
                                  height: 1.25,
                                  color: KioskColors.muted)),
                          const SizedBox(height: 10),
                        ],
                        _Lines(lines: lines),
                        if (onClose != null) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: onClose,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(160, 56),
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: KioskColors.border),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('처음 화면으로',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          // ── 오른쪽: 조작판의 대기 자리 + 큰 정지 ────────────────────
          Expanded(
            flex: 10,
            child: LayoutBuilder(builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _PanelMarker(
                    appliance: appliance,
                    stopButton: stopButton,
                    hovering: holdState == 'hovering_stop' ||
                        holdState == 'stopping',
                  ),
                ),
                const SizedBox(height: 14),
                if (stopLines.isNotEmpty) ...[
                  // 조작판 그림이 먼저 줄어든다. 정지 줄이 정지 버튼 몫까지 넘볼
                  // 만큼 길어질 때만(여러 결과가 겹친 드문 경우) 이 자리 안에서
                  // 스크롤한다 — 넘쳐서 버튼을 밀어내지 않는다. 막대가 보인다(B9).
                  ConstrainedBox(
                    key: const ValueKey('hold-stop-status'),
                    constraints: BoxConstraints(
                        maxHeight: (box.maxHeight - _stopButtonHeight - 16)
                            .clamp(0, double.infinity)),
                    child: KioskScrollArea(
                        child: _Lines(lines: stopLines, fontSize: 33)),
                  ),
                  const SizedBox(height: 2),
                ],
                // 정지는 어느 대기 상태에서든 닿는다 — 보내기만 하고 판정은 서버.
                Semantics(
                  button: true,
                  label: '$stopLabel. 작은 팔이 가전의 정지 버튼을 대신 눌러요',
                  child: ExcludeSemantics(
                    child: Material(
                      color: KioskColors.stop,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: const ValueKey('hold-stop'),
                        onTap: onStop,
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          height: _stopButtonHeight,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            // 이름이 길어져도('다시 정지 시도') 단추 크기는 그대로 — 글자가 줄어든다.
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.stop_circle_outlined,
                                      size: 44, color: Colors.white),
                                  const SizedBox(width: 12),
                                  Text(
                                    stopLabel,
                                    style: const TextStyle(
                                      fontSize: 38,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )),
          ),
        ],
      ),
    );

    return ColoredBox(
      color: KioskColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 연습은 맨 위 고정 띠로 말한다(§3-2) — 작은 칩은 처음 보는 사람이 놓쳤다.
          if (_mock) const KioskPracticeBand(),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// 큰 정지 버튼 높이 — 정지 상태 줄이 차지할 수 있는 높이의 상한을 이 값으로 뺀다.
const double _stopButtonHeight = 96;

class _Lines extends StatelessWidget {
  const _Lines({required this.lines, this.fontSize = 28});
  final List<(IconData, String, Color)> lines;

  /// 왼쪽 안내는 28, 정지 결과(정지 버튼 위 — 이 화면에서 가장 중요한 글자)는 33(2026-10-15 B9: 큰 글씨에서
  /// 왼쪽 안내가 33으로 거의 한 단어씩 줄바꿈돼 잘려 보였다).
  final double fontSize;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text, color) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 22, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: fontSize,
                        height: 1.3,
                        color: color == KioskColors.muted ? Colors.white : color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// 조작판 그림 위 대기 자리. 키오스크에는 등록 사진이 없어서(사진 파일은 서버에
/// 올리지 않는다) 등록된 버튼 배치로 그린다 — 정지 버튼은 빨간 테, 대기 중이면
/// 그 위에 누름 장치 표시.
/// 그림 위 안내 — 칸이 실제 버튼처럼 보여 눌러도 될 것 같다는 지적(2026-10-15 §2-2).
const kPanelCaption = '작은 팔이 누르는 자리예요 · 화면은 누르지 않아도 돼요';

/// 조작판 그림 위 대기 자리. 키오스크에는 등록 사진이 없어서(사진 파일은 서버에
/// 올리지 않는다) 등록된 버튼 배치로 그린다 — 정지 버튼은 빨간 테, 대기 중이면
/// 그 위에 작은 팔 표시. 칸은 면 없이 선만 그린 납작한 그림이다(누를 수 있는 단추로 보이지 않게).
class _PanelMarker extends StatelessWidget {
  const _PanelMarker({
    required this.appliance,
    required this.stopButton,
    required this.hovering,
  });

  final ApplianceMap? appliance;
  final String? stopButton;
  final bool hovering;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    return ExcludeSemantics(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KioskColors.border),
        ),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: a == null || a.isThinq || a.buttons.isEmpty
            ? const Center(
                child: Text(
                  '조작판 그림이 없어요',
                  style: TextStyle(fontSize: 22, color: KioskColors.muted),
                ),
              )
            // 정지 줄이 길어 그림 자리가 좁아지면(큰 글씨·확인 못 함) 안내 글부터, 더 좁으면 그림도 접는다 —
            // 정지 줄과 정지 버튼이 먼저다.
            : LayoutBuilder(builder: (context, outer) {
                if (outer.maxHeight < 48) return const SizedBox.expand();
                return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (outer.maxHeight >= 110) ...[
                    const Text(
                      kPanelCaption,
                      key: ValueKey('panel-caption'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, color: KioskColors.muted),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Expanded(
                    child: LayoutBuilder(builder: (context, box) {
                      final cw = box.maxWidth / a.cols;
                      final ch = box.maxHeight / a.rows;
                      return Stack(
                        children: [
                          for (final b in a.buttons)
                            Positioned(
                              left: b.x * cw + 3,
                              top: b.y * ch + 3,
                              width: cw - 6,
                              height: ch - 6,
                              child: _Cell(
                                label: b.label,
                                stop: b.label == stopButton,
                                carriage: hovering && b.label == stopButton,
                              ),
                            ),
                        ],
                      );
                    }),
                  ),
                ],
              );
              }),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.stop, required this.carriage});
  final String label;
  final bool stop;
  final bool carriage;

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: stop
              ? Border.all(color: KioskColors.danger, width: 3)
              : Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (carriage)
              FractionallySizedBox(
                widthFactor: 0.62,
                heightFactor: 0.62,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: KioskColors.warning, width: 2.5),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: stop ? FontWeight.w700 : FontWeight.w500,
                    color: stop ? Colors.white : KioskColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
