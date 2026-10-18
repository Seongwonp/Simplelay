import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/josa.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'done_view.dart' show kioskHomeButton;
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

  /// 사람이 닫아야 끝나는 결과(미확인·이상), 또는 연습 대기(평가 12차 10/18 — 연습은 실제 가전이 없어 정지를 기다리지 않고
  /// 나가도 된다)일 때만 있다. 실제 대기에는 없다 — 가전이 돌아가는 동안 정지가 닿아야 한다.
  final VoidCallback? onClose;

  /// 연습 대기에서 나가는 길 — 주 단추 '처음 화면으로'(결과 화면과 같은 단추). 미확인·이상은 종전 보조 단추.
  bool get _practiceExit => onClose != null && _mock && !_unconfirmed && !_fault && estopTitle == null;

  /// 비상 멈춤이 걸려 있으면 그 제목(위 띠와 같은 말, 2026-10-15). 걸려 있는 동안에는
  /// '돌아가고 있어요' 같은 제목을 쓰지 않는다 — 위 띠와 아래 제목이 서로 다른 말을 하지 않게.
  final String? estopTitle;

  bool get _fault => holdState == 'fault' || stopOutcome == 'drive_fault';

  bool get _mock => executionMode == 'mock';

  bool get _unconfirmed => stopOutcome == 'requested_unconfirmed';

  /// 작은 팔이 제자리로 돌아갔다고 서버가 알려 왔다(hold_state=parked).
  bool get _parked => holdState == 'parked';

  /// 연습 대기에서 정지를 보냈고 아직 대기 상태가 바뀌지 않았다 — 제목이 이 상태 하나만 말한다.
  bool get _practiceStopping => _mock && stopRequested && !stopFailed && holdState == 'hovering_stop';

  String get _name => appliance?.name ?? '가전';

  /// 가전 동작을 실제 전력으로 확인했나(출처 real, 연습 아님).
  bool get _operationReal =>
      operationConfirmed == true && operationSource == 'real' && !_mock;

  // 주어를 밝힌다(2026-10-15 문구 개선 §2-2) — 정지 대기·이동은 **작은 팔**, 돌아가는 것은 **가전**.
  // 가전이 돈다고는 전력으로 확인했을 때만 말한다. 아이콘이 상태를 함께 말한다(2026-10-16 §1-2).
  (String, IconData, Color) get _headline {
    if (estopTitle case final t?) {
      return ('$t. 가전을 봐 주세요', Icons.report, KioskColors.danger);
    }
    if (_fault) {
      return ('작은 팔에 문제가 생겼어요', Icons.error_outline, KioskColors.danger);
    }
    // 정지 미확인 — 상태 영역은 짧게, 바로 아래 첫 블록이 할 일, 무엇을 했는지는 그 아래 작게(2026-10-16 §1-2).
    if (_unconfirmed) {
      return ('가전이 멈췄는지 몰라요', Icons.help_outline, KioskColors.warning);
    }
    return switch (holdState) {
      'stopping' => (
          _mock ? '정지 버튼을 누르는 연습 중이에요' : '작은 팔이 정지 버튼을 누르고 있어요',
          Icons.touch_app_outlined,
          Colors.white
        ),
      'parking' => ('작은 팔이 제자리로 돌아가고 있어요', Icons.keyboard_return, Colors.white),
      'parked' => ('작은 팔이 제자리로 돌아갔어요', Icons.home_outlined, Colors.white),
      // 연습은 누르기를 다 마친 뒤 정지를 기다린다 — 제목이 그 상태를 말한다(평가 6차 10/18: '…연습 중' 제목 아래
      // '…연습을 마쳤어요'가 서로 다른 말이었다). 무엇을 했는지는 제목, 할 일은 아래 한 줄.
      // 정지를 보낸 뒤에는 상태가 바뀌었다 — '마쳤어요' 아래 '멈추는 중이에요'를 함께 두지 않고 지금 상태 한 문장(평가 11차 10/18).
      _ => _mock
          ? (_practiceStopping
              ? ('연습을 끝내는 중이에요', Icons.pan_tool_outlined, Colors.white)
              : ('연습이 끝났어요', Icons.check_circle_outline, Colors.white))
          : _operationReal
              ? (
                  '${withSubject(_name)} 돌아가고 있어요',
                  appliance?.icon ?? Icons.power_outlined,
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
          label: '작동 중',
          practice: _mock,
          suppressUnderEstop: true);
    }
    if (_fault || stopFailed) {
      return KioskStatusBand(
          tone: KioskBandTone.danger,
          icon: Icons.error_outline,
          label: _fault ? '작은 팔 문제' : '멈추기 실패',
          practice: _mock);
    }
    if (_unconfirmed) {
      return KioskStatusBand(
          tone: KioskBandTone.attention,
          icon: Icons.help_outline,
          label: kBandCheck,
          practice: _mock);
    }
    if (_mock) return const KioskStatusBand.practice();
    final waiting = holdState == 'hovering_stop' || holdState == 'stopping';
    return KioskStatusBand(
      tone: KioskBandTone.neutral,
      icon: Icons.pan_tool_outlined,
      label: waiting ? '작동 중' : '작동 끝',
    );
  }

  String get _operationLine {
    final ok = operationConfirmed;
    if (ok == null) return '가전이 켜졌는지는 몰라요';
    if (!ok) return '가전이 켜진 것은 못 봤어요';
    // 외부 평가 2026-10-13 M5: 출처가 real일 때만 확인이라고 말한다. 모의 실행·모의 입력은 연습 값,
    // 출처를 모르면 단정하지 않는다.
    if (_mock || operationSource == 'mock') {
      return '연습이라 가전은 보지 않아요';
    }
    return operationSource == 'real'
        ? '가전이 켜졌어요'
        : '가전이 켜졌는지 봐 주세요';
  }

  @override
  Widget build(BuildContext context) {
    if (estopTitle != null || KioskEstopScope.shownOf(context)) {
      final cancel = stopButton;
      // 사람이 직접 누를 칸을 버튼판에 주의색으로(평가 7차 10/18 — 오른쪽이 비어 같은 틀만 남았다). 자리를 못 찾으면 그림 없음.
      final pressCell = cancel == null ? null : KioskPanelPicture.uniqueButton(appliance, cancel);
      return KioskRunFrame(
        picture: pressCell == null
            ? null
            : KioskPanelPicture(
                appliance: appliance,
                current: pressCell,
                caution: true,
                caption: '직접 누를 버튼이에요',
                captionKey: const ValueKey('hold-estop-panel-caption'),
              ),
        band: _band,
        header: KioskStatusHeader(
            icon: Icons.pan_tool_outlined,
            title: '작은 팔을 쓸 수 없어요',
            iconColor: KioskColors.danger),
        body: KioskScrollArea(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KioskText(
                cancel == null
                    ? '가전 정지 버튼을 손으로 눌러 주세요'
                    : '$_name $cancel 버튼을 손으로 눌러 주세요',
                style: const TextStyle(
                    fontSize: KioskType.status,
                    color: Colors.white,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            // 회색 정지 단추가 왜 안 눌리는지(UI 평가 4차 10/17).
            KioskText('비상 버튼을 풀면 정지 버튼을 다시 쓸 수 있어요',
                textKey: ValueKey('hold-estop-stop-note'),
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
          ],
        )),
        // 자리·크기·이름은 그대로(디자인 규격 §1-1), 못 누르는 것은 흐린 테두리와 본문 한 줄이 말한다(UI 평가 4차 10/17).
        stop: const KioskStopButton(
            label: '정지',
            onPressed: null,
            buttonKey: ValueKey('hold-stop'),
            semanticsLabel: '정지 버튼을 쓸 수 없어요. 가전 정지 버튼을 손으로 눌러 주세요'),
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
              ? '지금 $_name 정지 버튼을 손으로 눌러 주세요'
              : '지금 $_name $cancel 버튼을 손으로 눌러 주세요',
          KioskColors.warning
        ),
      // 가전이 멈췄다는 말은 RPi4가 전력 하강으로 확인한 때만(hold_stop_outcome == stopped).
      if (stopOutcome == 'stopped')
        (Icons.check, '${withSubject(_name)} 멈췄어요', Colors.white),
      // 마지막 시도가 실패했으면 앞선 "멈추는 중"은 지운다 — 지금 할 일은 다시 누르기다.
      // 보내기 화살표·'보냈어요'는 기계가 한 일이었다(평가 4차 10/18) — 사람이 볼 상태와 할 일로. 멈췄다고 단정하지 않는다.
      // 연습은 위 제목('연습으로 멈추는 중이에요')이 말한다 — 같은 말을 또 두지 않는다(평가 11차 10/18).
      if (stopRequested && !stopFailed && holdState == 'hovering_stop' && !_mock)
        (Icons.pan_tool_outlined, '멈추는 중이에요. 가전을 봐 주세요', Colors.white),
      if (stopFailed)
        (
          Icons.error_outline,
          '정지가 닿지 않았어요. 정지를 다시 누르거나 가전 전원을 직접 꺼 주세요.',
          KioskColors.danger
        ),
    ];

    // 설명 — 할 일 아래 본문 크기로.
    final lines = <(IconData, String, Color)>[
      // 연습을 마친 대기에는 정지 안내 문장을 두지 않는다(평가 14차 10/18) — 정지 버튼은 늘 같은 자리에 있고, 나가는 길은
      // '처음 화면으로'다. 연습은 제목이 이미 '누르기 연습을 마쳤어요'라고 말한다 — 같은 말을 한 번 더 두지 않는다(평가 6차 10/18).
      if (!_mock && waiting && buttonsPressed != null && buttonsPressed! > 0)
        (Icons.check_circle_outline, '버튼 $buttonsPressed개를 눌렀어요', KioskColors.muted),
      // 정지 대기 안내는 흰색 — 주의색은 확인 못 함에만 쓴다(2026-10-15). 연습의 할 일은 위 첫 블록 한 줄뿐이다.
      // 조준경 아이콘은 뜻이 없었다(평가 6차 10/18) — 정보 아이콘.
      if (!_mock && holdState == 'hovering_stop')
        (
          Icons.info_outline,
          cancel == null
              ? '정지를 누르면 작은 팔이 가전 정지 버튼을 대신 눌러요'
              : '정지를 누르면 작은 팔이 $cancel 버튼을 대신 눌러요',
          KioskColors.muted
        ),
      if (_unconfirmed)
        (
          Icons.info_outline,
          // 위 줄('…' 버튼을 직접 눌러 주세요)과 같은 이름으로(외부 평가 10/16 4차).
          // '대신 눌렀어요'는 바로 위 '직접 눌러 주세요'와 엇갈렸다(평가 8차 10/18) — 작은 팔도 눌렀지만 눌린 것은
          // 확인하지 못했다고 정직하게(가전 전력이 떨어지는 것을 보지 못한 상태다).
          _mock
              ? (cancel == null ? '연습으로 정지 버튼을 눌렀어요' : '연습으로 $cancel 버튼을 눌렀어요')
              // 주어는 제목과 같은 가전 쪽 하나로(평가 16차 10/18 — '가전이 …' 제목 아래 '작은 팔도 …'가 섞였다).
              : (cancel == null
                  ? '정지 버튼이 눌렸는지 확인이 안 됐어요'
                  : '$cancel 버튼이 눌렸는지 확인이 안 됐어요'),
          KioskColors.muted
        ),
      // 작은 팔이 제자리로 돌아간 것은 서버가 알려 온 사실(hold_state=parked — RPi4가 제자리 이동을 모션 보드 응답으로 마친 뒤에만
      // 보낸다). 그때는 다시 멈출 것이 없다 — 정지 단추는 이름 '정지' 그대로 같은 자리, 할 일은 손으로 누르기(평가 16차 10/18).
      if (_unconfirmed && _parked)
        (Icons.check, '작은 팔은 제자리에 있어요', KioskColors.muted),
      if (detail != null && detail!.isNotEmpty && stopOutcome != 'stopped')
        (
          _fault ? Icons.power_settings_new : Icons.info_outline,
          detail!,
          _fault ? KioskColors.danger : KioskColors.muted
        ),
    ];

    // 실행 근거(연습용 값인지·실제 확인인지)는 안전 문장이다 — 스크롤 없이 늘
    // 보이도록 스크롤 영역 밖, 상태 영역 바로 아래에 고정한다(10/5 수리).
    // 연습에는 두지 않는다 — '연습이라 가전은 보지 않아요'는 위 연습 띠와 부딪혔다(평가 4차 10/18).
    final provenance = <(IconData?, String, Color)>[
      if (waiting && !_mock)
        (
          null, // 뜻 없는 번개 아이콘은 뺀다(2차 평가 10/18). 주의는 글자 색이 아니라 문장이 말한다.
          _operationLine,
          _operationReal || _mock || operationSource == 'mock'
              ? KioskColors.muted
              : KioskColors.warning
        ),
    ];

    // 확인 못 함이면 단추 이름이 할 일을 말한다 — 자리·크기·색은 그대로(원칙 0-4).
    // '다시 정지 시도'는 '다시 / 정지 시도'로 꺾였다(2차 평가 10/18) — 한 줄 '다시 멈추기'.
    final stopLabel = _unconfirmed && !_parked ? '다시 멈추기' : '정지';

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
                // 연습에는 끝날 가전이 없다 — '끝나는 시간은 몰라요'를 두지 않는다(평가 4차 10/18).
                if (waiting && !_mock) ...[
                  KioskText('끝나는 시간은 몰라요',
                      style: TextStyle(
                          fontSize: KioskType.body,
                          height: 1.25,
                          color: KioskColors.muted)),
                  const SizedBox(height: 10),
                ],
                _Lines(lines: lines),
              ],
            ),
          ),
        ),
        // 나가는 길은 결과 화면과 같은 모양·같은 자리(왼쪽 아래, 평가 15차 10/18) — 연습 대기는 주 크기(평가 12차), 정지 미확인·
        // 이상은 정지가 주인공이라 보조 크기(아이콘·글자·색은 같다 — 예전에는 작은 테두리·아이콘 없음이라 모양이 달랐다).
        if (onClose != null) ...[
          const SizedBox(height: KioskSpace.xs),
          kioskHomeButton(onClose!, key: const ValueKey('hold-home'), compact: !_practiceExit),
        ],
      ],
    );

    // 작은 팔이 기다리는 정지 버튼 칸 — 대기 중일 때만 앰버로 채운다(§1-6). 빨강은 쓰지 않는다
    // (화면의 빨간 정지 단추와 한 묶음처럼 보이지 않게, §1-1).
    final a = appliance;
    final hovering = holdState == 'hovering_stop' || holdState == 'stopping';
    // 연습을 마친 대기에는 칸을 강조하지 않는다(평가 16차 10/18 — '연습이 끝났어요' 옆 강조된 '취소'가 할 일처럼 보였다).
    final waitCell = a == null || !hovering || (_mock && holdState == 'hovering_stop')
        ? null
        : a.buttons.where((b) => b.label == stopButton).firstOrNull;

    // 정지 미확인 — 사람이 직접 누를 칸을 주의색으로(평가 8차 10/18, 비상 버튼 대기와 같은 모양). '작은 팔이 누르는
    // 자리예요. 화면은 누르지 않아도 돼요'는 바로 옆 '직접 눌러 주세요'와 엇갈렸다. 자리를 못 찾으면 칸 없이 같은 제목.
    final pressCell = _unconfirmed && cancel != null ? KioskPanelPicture.uniqueButton(a, cancel) : null;

    return KioskRunFrame(
      band: _band,
      header: KioskStatusHeader(
          icon: headIcon, title: headline, iconColor: headColor),
      body: body,
      picture: _unconfirmed
          ? KioskPanelPicture(
              appliance: a,
              current: pressCell,
              caution: true,
              caption: '직접 누를 버튼이에요',
              captionKey: const ValueKey('panel-caption'),
            )
          : KioskPanelPicture(
              appliance: a,
              current: waitCell,
              // 기다리는 칸은 흰 테로만(평가 12차 10/18) — 진행색(파랑) 채움은 '지금 누르는 중'으로 읽혔다.
              resting: holdState == 'hovering_stop',
              caption: _mock ? kPracticePanelCaption : kPanelCaption,
              captionKey: const ValueKey('panel-caption'),
            ),
      // 정지는 어느 대기 상태에서든 닿는다 — 보내기만 하고 판정은 서버.
      stop: KioskStopButton(
        label: stopLabel,
        onPressed: onStop,
        buttonKey: const ValueKey('hold-stop'),
        semanticsLabel: '$stopLabel. 작은 팔이 가전 정지 버튼을 대신 눌러요',
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
  final List<(IconData?, String, Color)> lines;

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
                  if (icon != null) ...[Padding(
                    padding: EdgeInsets.only(top: fontSize * 0.15),
                    child: Icon(icon, size: fontSize * 1.05, color: color),
                  ),
                  const SizedBox(width: 10)],
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
const kPanelCaption = '작은 팔이 누르는 자리예요. 화면은 누르지 않아도 돼요';

/// 연습의 그림 위 안내 — 실행 중·마친 뒤 대기 모두 같은 말(평가 13차 10/18: 마친 뒤만 '작은 팔이 누르는 자리예요'였다).
const kPracticePanelCaption = '연습으로 누르는 자리예요. 화면은 누르지 않아도 돼요';
