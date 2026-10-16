import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/josa.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_text.dart';
import 'run_frame.dart';
import 'estop_banner.dart';
import 'status_band.dart';

/// 동작 중 화면(UI 확정 2026-09-30 §3-3) — 버튼을 다 누른 뒤 가전이 돌아가는 동안.
///
/// 작은 팔(누름 장치)은 정지 버튼 위에서 기다린다(`/status.hold_state = hovering_stop`).
/// 큰 "정지"는 `/stop`을 보내고, 서버는 그 정지를 **정지 버튼 누름**으로 전달한다.
/// 판정(정지됨·미확인·구동부 이상)은 RPi4가 하고 서버가 옮긴다 — 화면은 지어내지
/// 않는다. 특히:
/// - "가전이 멈췄어요"는 `hold_stop_outcome = stopped`(전력 하강 확인)일 때만.
/// - 남은 시간은 서버가 주지 않는다(전력 추정 미구현). 대신 시작한 뒤 흐른 시간을
///   값을 만들지 않고 남은 시간을 모른다고 안내한다.
/// - 연습용(mock) 대기는 위 청록 띠로 연습이라고 적는다(2026-10-15, 2026-10-16 §4).
///
/// 배치(2026-10-16 디자인 규격 §1-1·§1-2): 실행 화면과 같은 틀([KioskRunFrame]) — 위 상태 띠, 왼쪽 위 상태
/// 영역, 그 바로 아래 **할 일**(정지 미확인이면 "지금 …버튼을 직접 눌러 주세요"가 첫 블록), 설명은 그 아래 작게.
/// 정지 단추는 세 화면에서 같은 자리·크기·모양이다.
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

  bool get _unconfirmed => stopOutcome == 'requested_unconfirmed';

  String get _name => appliance?.name ?? '가전';

  /// 가전 동작을 실제 전력으로 확인했나(출처 real, 연습 아님).
  bool get _operationReal =>
      operationConfirmed == true && operationSource == 'real' && !_mock;

  // 주어를 밝힌다(2026-10-15 문구 개선 §2-2) — 정지 대기·이동은 **작은 팔**, 돌아가는 것은 **가전**.
  // 가전이 돈다고는 전력으로 확인했을 때만 말한다. 아이콘이 상태를 함께 말한다(2026-10-16 §1-2).
  (String, IconData, Color) get _headline {
    if (estopTitle case final t?) {
      return ('$t · 가전이 멈췄는지는 직접 봐 주세요', Icons.report, KioskColors.danger);
    }
    if (_fault) {
      return ('작은 팔 장치에 문제가 생겼어요', Icons.error_outline, KioskColors.danger);
    }
    // 정지 미확인 — 상태 영역은 짧게, 바로 아래 첫 블록이 할 일, 무엇을 했는지는 그 아래 작게(2026-10-16 §1-2).
    if (_unconfirmed) {
      return ('멈췄는지 확인하지 못했어요', Icons.help_outline, KioskColors.warning);
    }
    return switch (holdState) {
      'stopping' => (
          _mock ? '정지 버튼을 짚고 있어요' : '작은 팔이 정지 버튼을 누르고 있어요',
          Icons.touch_app_outlined,
          Colors.white
        ),
      'parking' => ('작은 팔이 제자리로 돌아가고 있어요', Icons.keyboard_return, Colors.white),
      'parked' => ('작은 팔이 제자리로 돌아갔어요', Icons.home_outlined, Colors.white),
      _ => _mock
          ? ('$_name 연습 중', Icons.hourglass_top, Colors.white)
          : _operationReal
              ? (
                  '${withSubject(_name)} 돌아가고 있어요',
                  appliance?.icon ?? Icons.widgets_outlined,
                  Colors.white
                )
              : (
                  '작은 팔이 $_name 옆에서 기다리고 있어요',
                  Icons.hourglass_top,
                  Colors.white
                ),
    };
  }

  /// 위 상태 띠 — 일반 = 중립, 확인 필요 = 앰버, 실패·비상 = 빨강, 연습 = 청록(2026-10-16 §4).
  KioskStatusBand get _band {
    // 비상 버튼 걸림 — 위 비상 버튼 띠와 아래 제목이 이미 '비상 버튼'을 말한다. 상태 띠는 단계 이름만 빨강으로.
    if (estopTitle != null) {
      return KioskStatusBand(
          tone: KioskBandTone.danger,
          icon: Icons.report,
          label: '정지 대기',
          practice: _mock,
          suppressUnderEstop: true);
    }
    if (_fault || stopFailed) {
      return KioskStatusBand(
          tone: KioskBandTone.danger,
          icon: Icons.error_outline,
          label: _fault ? '장치 문제' : '정지 요청 실패',
          practice: _mock);
    }
    if (_unconfirmed) {
      return KioskStatusBand(
          tone: KioskBandTone.attention,
          icon: Icons.help_outline,
          label: '확인 필요',
          practice: _mock);
    }
    if (_mock) return const KioskStatusBand.practice();
    final waiting = holdState == 'hovering_stop' || holdState == 'stopping';
    return KioskStatusBand(
      tone: KioskBandTone.neutral,
      icon: Icons.pan_tool_outlined,
      label: waiting ? '정지 대기' : '정지 대기 끝',
    );
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
    if (estopTitle != null || KioskEstopScope.shownOf(context)) {
      final cancel = stopButton;
      return KioskRunFrame(
        band: _band,
        header: const KioskStatusHeader(
            icon: Icons.pan_tool_outlined,
            title: '작은 팔로 조작할 수 없어요',
            iconColor: KioskColors.danger),
        body: KioskScrollArea(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KioskText(
                cancel == null
                    ? '가전의 정지·취소 버튼을 직접 눌러 주세요'
                    : "$_name의 '$cancel' 버튼을 직접 눌러 주세요",
                style: const TextStyle(
                    fontSize: KioskType.status,
                    color: Colors.white,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            const KioskText('가전이 멈췄는지는 직접 확인해 주세요',
                style:
                    TextStyle(fontSize: KioskType.body, color: Colors.white)),
          ],
        )),
        stop: const KioskStopButton(
            label: '정지',
            onPressed: null,
            buttonKey: ValueKey('hold-stop'),
            semanticsLabel: '정지 조작 불가. 가전의 취소 버튼을 직접 눌러 주세요'),
      );
    }
    final (headline, headIcon, headColor) = _headline;
    final waiting = holdState == 'hovering_stop' || holdState == 'stopping';
    final cancel = stopButton;

    // 할 일·정지 결과 — 상태 영역 바로 아래 첫 블록(§1-2). 정지 미확인이면 가장 큰 글자가 할 일 한 가지다(원칙 0-3).
    final first = <(IconData, String, Color)>[
      if (_unconfirmed)
        (
          Icons.touch_app_outlined,
          cancel == null
              ? '지금 $_name의 정지·취소 버튼을 직접 눌러 주세요'
              : "지금 $_name의 '$cancel' 버튼을 직접 눌러 주세요",
          KioskColors.warning
        ),
      // 가전이 멈췄다는 말은 RPi4가 전력 하강으로 확인한 때만(hold_stop_outcome == stopped).
      if (stopOutcome == 'stopped')
        (Icons.check, '${withSubject(_name)} 멈춘 것을 전력으로 확인했어요', Colors.white),
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

    // 설명 — 할 일 아래 본문 크기로.
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
      if (_unconfirmed)
        (
          Icons.info_outline,
          // 위 줄('…' 버튼을 직접 눌러 주세요)과 같은 이름으로(외부 평가 10/16 4차).
          _mock
              ? (cancel == null ? '연습으로 정지 버튼을 짚었어요' : "연습으로 '$cancel' 버튼을 짚었어요")
              : (cancel == null ? '작은 팔이 정지 버튼을 대신 눌렀어요' : "작은 팔이 '$cancel' 버튼을 대신 눌렀어요"),
          KioskColors.muted
        ),
      if (_unconfirmed && holdState == 'parked')
        (Icons.check, '작은 팔이 제자리로 돌아갔어요', KioskColors.muted),
      if (detail != null && detail!.isNotEmpty && stopOutcome != 'stopped')
        (
          _fault ? Icons.power_settings_new : Icons.info_outline,
          detail!,
          _fault ? KioskColors.danger : KioskColors.muted
        ),
    ];

    // 실행 근거(연습용 값인지·실제 확인인지)는 안전 문장이다 — 스크롤 없이 늘
    // 보이도록 스크롤 영역 밖, 상태 영역 바로 아래에 고정한다(10/5 수리).
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
    final stopLabel = _unconfirmed ? '다시 정지 시도' : '정지';

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (provenance.isNotEmpty) ...[
          _Lines(lines: provenance),
          const SizedBox(height: 2),
        ],
        // 넘치면 스크롤 막대가 보인다(2026-10-15 B9). 할 일·정지 결과가 맨 위라 스크롤 없이 먼저 보인다.
        Expanded(
          child: KioskScrollArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (first.isNotEmpty) ...[
                  _Lines(
                    key: const ValueKey('hold-stop-status'),
                    lines: first,
                    fontSize: KioskType.status,
                    weight: FontWeight.w800,
                  ),
                  const SizedBox(height: 6),
                ],
                if (waiting) ...[
                  const Text('남은 시간을 아직 알 수 없어요',
                      style: TextStyle(
                          fontSize: KioskType.body,
                          height: 1.25,
                          color: KioskColors.muted)),
                  const SizedBox(height: 10),
                ],
                _Lines(lines: lines),
                if (onClose != null) ...[
                  const SizedBox(height: 8),
                  // 보조 단추(테두리) — 정지 단추·할 일과 주인공을 다투지 않게(§1-5).
                  OutlinedButton(
                    onPressed: onClose,
                    style: KioskButtons.secondary(
                        foreground: Colors.white, border: KioskColors.muted),
                    child: const Text('처음 화면으로',
                        style: TextStyle(
                            fontSize: KioskType.body,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );

    // 작은 팔이 기다리는 정지 버튼 칸 — 대기 중일 때만 앰버로 채운다(§1-6). 빨강은 쓰지 않는다
    // (화면의 빨간 정지 단추와 한 묶음처럼 보이지 않게, §1-1).
    final a = appliance;
    final hovering = holdState == 'hovering_stop' || holdState == 'stopping';
    final waitCell = a == null || !hovering
        ? null
        : a.buttons.where((b) => b.label == stopButton).firstOrNull;

    return KioskRunFrame(
      band: _band,
      header: KioskStatusHeader(
          icon: headIcon, title: headline, iconColor: headColor),
      body: body,
      picture: KioskPanelPicture(
        appliance: a,
        current: waitCell,
        caption: kPanelCaption,
        captionKey: const ValueKey('panel-caption'),
      ),
      // 정지는 어느 대기 상태에서든 닿는다 — 보내기만 하고 판정은 서버.
      stop: KioskStopButton(
        label: stopLabel,
        onPressed: onStop,
        buttonKey: const ValueKey('hold-stop'),
        semanticsLabel: '$stopLabel. 작은 팔이 가전의 정지 버튼을 대신 눌러요',
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({
    super.key,
    required this.lines,
    this.fontSize = KioskType.body,
    this.weight = FontWeight.w400,
  });
  final List<(IconData, String, Color)> lines;

  /// 설명은 본문, 할 일·정지 결과(상태 영역 바로 아래 첫 블록)는 상태 크기(2026-10-16 §1-3).
  final double fontSize;
  final FontWeight weight;

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
                  Padding(
                    padding: EdgeInsets.only(top: fontSize * 0.15),
                    child: Icon(icon, size: fontSize * 1.05, color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: KioskText(
                      text,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: weight,
                        height: 1.3,
                        // 글자는 흰색 — 주의·실패는 아이콘 색이 말한다(앰버 지시문이 정지 단추와 다투지 않게, §0-3).
                        color: color == KioskColors.danger
                            ? KioskColors.danger
                            : Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// 그림 위 안내 — 칸이 실제 버튼처럼 보여 눌러도 될 것 같다는 지적(2026-10-15 §2-2).
const kPanelCaption = '작은 팔이 누르는 자리예요 · 화면은 누르지 않아도 돼요';
