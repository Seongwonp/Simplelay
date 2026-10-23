import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/josa.dart';
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

/// LG 가전 조작 화면의 큰 상태 한 줄(평가 11차 10/18) — '공기청정기가 켜져 있어요 · 바람 약' · '공기청정기가 꺼져 있어요'.
/// 읽은 전원 값이 없으면 null(지어내지 않는다). 바람은 켜져 있고 읽은 값이 있을 때만.
String? thinqStateHeadline(String applianceName, Map<String, dynamic> state) {
  final controls = thinqControlsFor(state);
  if (controls.isEmpty) return null;
  String? wordOf(ThinqControl c) => c.choices.where((e) => e.$1 == c.current).map((e) => e.$2).firstOrNull;
  final power = controls.where((c) => c.isPower).firstOrNull?.current;
  final who = withSubject(applianceName);
  if (power == 'POWER_OFF') return '$who 꺼져 있어요';
  if (power != 'POWER_ON') return null;
  final wind = controls.where((c) => !c.isPower).map(wordOf).whereType<String>().firstOrNull;
  return wind == null ? '$who 켜져 있어요' : '$who 켜져 있어요 · 바람 $wind';
}

/// 공기가 나쁠 때 할 일 한 줄(평가 12차 10/18 — '공기 나빠요'에 할 일이 없었다). 가전이 매긴 등급이 나쁨·매우 나쁨일 때만.
const kThinqAirWindHint = '바람을 세게 해 보세요';

/// 꺼져 있으면 바람 세기를 바꿀 수 없다(전원을 켠 뒤 바꿀 수 있어요) — 켜기를 권한다.
const kThinqAirPowerHint = '공기청정기를 켜 보세요';

/// 공기 등급 [grade]와 읽은 상태로 할 일 한 줄. 근거(나쁨 등급·전원 값)가 없거나 이미 바람이 강이면 null(지어내지 않는다).
String? thinqAirHint(String? grade, Map<String, dynamic> state) {
  if (grade != 'BAD' && grade != 'VERY_BAD') return null;
  final controls = thinqControlsFor(state);
  final power = controls.where((c) => c.isPower).firstOrNull?.current;
  if (power == 'POWER_OFF') return kThinqAirPowerHint;
  if (power != 'POWER_ON') return null;
  final wind = controls.where((c) => !c.isPower).firstOrNull?.current;
  if (wind == null || wind == 'HIGH' || wind == 'POWER') return null;
  return kThinqAirWindHint;
}

/// 조작 단추가 ✓로 이미 말하는 상태 줄(평가 11차 10/18) — 왼쪽 '지금 상태'에 두 번 두지 않는다.
const _shownByControls = {'전원', '바람 세기'};

/// 큰 글씨 상세의 짧은 상태 한 줄(접근성 감사 10/18) — '지금 상태' 칸과 같은 줄들(조작 단추가 말하는 줄·먼지 숫자는 뺀다)을
/// '이름 값'으로 이어 쓴다. 보여 줄 줄이 없으면 null. 공기 등급·먼지는 아래 칸의 '미세먼지 보기'가 말한다.
String? thinqStateBrief(Map<String, dynamic> map, {bool hideControlled = true}) {
  const dust = {'초미세먼지', '미세먼지'};
  final rows = thinqStateRows(map)
      .where((r) => !dust.contains(r.label))
      .where((r) => !(hideControlled && _shownByControls.contains(r.label)))
      .toList();
  if (rows.isEmpty) return null;
  return rows.map((r) => '${r.label} ${r.value}').join(' · ');
}

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
    this.lookupRequest,
  });

  final ApplianceMap appliance;

  /// GET /thinq/status/{id}. null이면 허브가 없어 읽지 못한다.
  final Future<KioskThinqStatus> Function()? readStatus;

  /// POST /thinq/command — 조작마다 새 요청 번호(`client_request_id`)를 함께 넘긴다(검토 10/19).
  final Future<KioskJobAccepted> Function(String action, Map<String, Object> args, String clientRequestId)?
      sendCommand;

  /// GET /jobs/by-request/{id} — 응답을 잃은 조작이 접수됐는지 찾는다. null이면 찾지 않고 '됐는지 확인하지 못했어요'.
  final Future<KioskRequestLookup> Function(String clientRequestId)? lookupRequest;

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
    // 보내는 중이면 다시 누름을 받지 않는다 — 확인 창이 걷히기 전 두 번 누름이 같은 조작을 두 번 보냈다(검토 10/19).
    if (_sending) return;
    final send = widget.sendCommand;
    if (send == null) {
      setState(() {
        _pending = null;
        _message = '본체에 연결되면 바꿀 수 있어요.';
      });
      return;
    }
    // 보내기 전에 보내는 중으로 — 확인 창 닫기와 한 번에.
    setState(() {
      _pending = null;
      _message = null;
      _sending = true;
    });
    final requestId = newKioskRequestId();
    final label = change.control.doneLabel(widget.appliance.displayName, change.word);
    try {
      final accepted = await send(change.control.action, {change.control.arg: change.value}, requestId);
      if (!mounted) return;
      setState(() => _sending = false);
      widget.onAccepted(accepted.jobId, label);
    } on KioskApiException catch (e) {
      if (!mounted) return;
      final refusal = thinqCommandRefusal(e.statusCode, e.detail);
      // 분명한 거절만 그 문장. 그 밖(5xx)은 접수됐을 수 있다 — 응답을 잃은 것과 같이 찾는다.
      if (refusal != null) {
        setState(() {
          _sending = false;
          _message = refusal;
        });
        return;
      }
      await _recover(requestId, label);
    } catch (_) {
      // 시간 초과·끊김 — 허브가 이미 받았을 수 있다.
      if (!mounted) return;
      await _recover(requestId, label);
    }
  }

  /// 응답을 잃은 조작을 요청 번호로 찾는다(검토 10/19) — 접수됐으면 그 실행을 따라가고, 본체가 모르는 번호라고 하면 받지
  /// 못했다고 말한다. 옛 본체·조회 실패면 종전처럼 됐는지 모른다고 말하고 상태를 다시 읽는다.
  Future<void> _recover(String requestId, String label) async {
    final lookup = widget.lookupRequest;
    final found = lookup == null
        ? const KioskRequestLookup(KioskRequestLookupKind.unsupported)
        : await lookup(requestId);
    if (!mounted) return;
    if (found.kind == KioskRequestLookupKind.found && found.jobId != null) {
      setState(() => _sending = false);
      widget.onAccepted(found.jobId!, label);
      return;
    }
    setState(() {
      _sending = false;
      _message = found.kind == KioskRequestLookupKind.unknown ? kThinqNotReceived : kThinqUnknownOutcome;
    });
    unawaited(_read());
  }

  @override
  Widget build(BuildContext context) {
    final large = KioskLayout.isLarge(context);
    final estop = KioskEstopScope.shownOf(context);
    final status = _status;
    final state = _loading ? null : status;
    final map = state != null && state.ok ? state.stateMap : null;
    final hasControls = map != null && thinqControlsFor(map).isNotEmpty;
    final left = _StateCard(
      status: state,
      loading: _loading || status == null,
      onReread: _loading || _sending ? null : _read,
      hideControlled: hasControls,
    );
    // 큰 상태 한 줄(평가 11차 10/18) — 지금 상태를 문장 하나로. 아래 3분의 1이 비어 있던 자리를 위로 끌어 쓴다.
    final headlineText = map == null ? null : thinqStateHeadline(widget.appliance.displayName, map);
    final Widget? headline = headlineText == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: KioskSpace.sm),
            child: KioskText(headlineText,
                textKey: const ValueKey('thinq-state-headline'),
                style: const TextStyle(
                    fontSize: KioskType.status, fontWeight: FontWeight.w800, color: Colors.white, height: 1.25)),
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
    final brief = large && map != null ? thinqStateBrief(map, hideControlled: hasControls) : null;
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
                    // 큰 상태 한 줄이 맨 위(평가 12차 10/18 — 큰 글씨에서만 조작 아래로 내려가 지금 상태를 먼저 못 봤다), 그다음
                    // 조작 — 큰 글씨에서 켜기·끄기가 스크롤 아래로 밀렸다(UI 평가 10/17). 상태 칸은 그 아래.
                    // 큰 글씨에서는 상태 칸이 조작 아래로 밀려 첫 화면에서 잘렸다(접근성 감사 10/18) — 큰 상태 한 줄 바로 아래에
                    // 나머지 상태를 짧게 한 줄(예: '운전 공기 깨끗하게 · 필터 87%'). 자세한 칸은 그대로 아래에 둔다.
                    children: [
                      if (headline != null) headline,
                      if (brief != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: KioskSpace.sm),
                          child: KioskText(brief,
                              textKey: const ValueKey('thinq-state-brief'),
                              style: const TextStyle(fontSize: KioskType.body, color: Colors.white, height: 1.25)),
                        ),
                      right,
                      const SizedBox(height: 16),
                      left,
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (headline != null) headline,
                      // 왼쪽 상태 카드와 오른쪽 조작 단추의 아래 끝을 맞춘다(평가 15차 10/18 — 카드 끝과 단추 끝이 어긋났다):
                      // 한 스크롤 안에서 두 칸을 같은 높이로 세운다(카드가 오른쪽 높이만큼 늘어난다).
                      Expanded(
                        child: KioskScrollArea(
                          key: const ValueKey('thinq-panel-columns'),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 5, child: left),
                                const SizedBox(width: 20),
                                Expanded(flex: 6, child: right),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        if (pending != null)
          Positioned.fill(
            child: _ChangeConfirm(
              question: pending.control.question(widget.appliance.displayName, pending.value, pending.word),
              // 비상 멈춤이 걸리면 묻던 것도 보내지 않는다.
              onConfirm: estop ? null : () => _send(pending),
              onCancel: () => setState(() => _pending = null),
            ),
          ),
      ],
    );
  }
}

/// 왼쪽 — 지금 상태. 공기는 '공기 나빠요' 한 줄 + 색이고, 먼지 숫자·등급 출처는 '미세먼지 보기'를 눌러야 보인다
/// (2차 평가 10/18, 이름은 평가 11차 10/18 — '자세히'는 무엇을 보여 주는지 몰랐다).
class _StateCard extends StatefulWidget {
  const _StateCard(
      {required this.status, required this.loading, required this.onReread, this.hideControlled = false});

  final KioskThinqStatus? status;
  final bool loading;
  final VoidCallback? onReread;

  /// 오른쪽 조작 단추가 ✓로 말하는 줄(전원·바람 세기)을 뺀다(평가 11차 10/18 — 같은 정보 두 번).
  final bool hideControlled;

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
      body = [
        KioskText('지금 상태를 보고 있어요…',
            textKey: const ValueKey('thinq-reading'),
            style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
      ];
    } else if (!s.ok) {
      body = [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: KioskColors.warning, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: KioskText(
                  '지금 상태를 못 봤어요. ${s.failure!.replaceFirst(RegExp(r'\.$'), '')}'
                  "${onReread != null ? ". '새로 보기'로 다시 볼 수 있어요." : ''}",
                  textKey: const ValueKey('thinq-read-failed'),
                  style: const TextStyle(fontSize: KioskType.body, color: Colors.white, height: 1.3)),
            ),
          ],
        ),
      ];
    } else {
      final map = s.stateMap;
      final all = thinqStateRows(map);
      final rows = all
          .where((r) => !_dustLabels.contains(r.label))
          .where((r) => !(widget.hideControlled && _shownByControls.contains(r.label)))
          .toList();
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
          KioskText('보여 줄 상태가 없어요',
              style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted))
        else
          for (final row in rows) _StateRowView(row: row),
        if (dust.isNotEmpty) ...[
          const SizedBox(height: KioskSpace.xs),
          // 공기 아이콘 오른쪽 한 글 선에 공기 한 줄·할 일·'미세먼지 보기'를 모두 둔다(평가 15차 10/18 — 할 일만 들여 쓰고
          // 단추는 카드 왼쪽 끝이라 들여쓰기가 어긋났다).
          Row(
            key: const ValueKey('thinq-air-block'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.air, size: 26, color: airGradeColor(grade)),
              const SizedBox(width: KioskSpace.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
          KioskText(grade == null ? '공기' : airSentence(grade),
              textKey: const ValueKey('thinq-air-summary'),
              style: TextStyle(
                  fontSize: KioskType.body,
                  fontWeight: FontWeight.w800,
                  color: grade == null ? Colors.white : airGradeColor(grade))),
          // 공기가 나쁠 때만 할 일 한 줄(평가 12차 10/18).
          if (thinqAirHint(grade, map) case final hint?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: KioskText(hint,
                  textKey: const ValueKey('thinq-air-hint'),
                  style: const TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          // 무엇을 보는지 말하는 단추(평가 11차 10/18 — '자세히'는 무엇을 보여 주는지 몰랐다). 이름이 길어져 공기 한 줄
          // 옆이 아니라 그 아래에 둔다(한 줄 옆에 두면 '공기 나빠요'가 낱말 가운데서 꺾였다).
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const ValueKey('thinq-air-more'),
              onPressed: () => setState(() => _airOpen = !_airOpen),
              style: KioskButtons.secondary(foreground: Colors.white, border: KioskColors.border)
                  .copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.sm)),
              ),
              child: KioskText(_airOpen ? '접기' : '미세먼지 보기',
                  style: const TextStyle(fontSize: KioskType.caption)),
            ),
          ),
                  ],
                ),
              ),
            ],
          ),
          if (_airOpen) ...[
            for (final row in dust) _StateRowView(row: row),
            if (total != null && kAirGradeWords.containsKey(total))
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: KioskText('종합 등급은 공기청정기가 정한 거예요',
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
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted, height: 1.3)),
          ),
        // 연습이면 읽은 시각 줄('연습 화면이에요. 진짜 값이 아니에요')을 두지 않는다 — 조작 칸 위 연습 안내가 같은 말을 한다
        // (평가 5차 10/18). 조작 칸이 없을 때(읽기 실패)는 그대로 남는다.
        if (s.readAt != null && !(s.mock && s.ok)) ...[
          const SizedBox(height: 8),
          KioskText(thinqReadTimeLine(s.readAt!, mock: s.mock),
              textKey: const ValueKey('thinq-read-time'),
              style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
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
          KioskText(row.label, style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
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
  Widget build(BuildContext context) => Row(
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
      children.add(KioskText('지금 상태를 본 뒤 바꿀 수 있어요. 왼쪽 새로 보기를 눌러 주세요.',
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
        children.add(KioskText('이 가전은 휴대폰 앱에서 바꿀 수 있어요.',
            textKey: ValueKey('thinq-controls-phone'),
            style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted, height: 1.3)));
      }
      for (final (ci, control) in controls.indexed) {
        final blockedByPower = powerOff && !control.isPower;
        final enabled = !estop && !busy && !blockedByPower;
        children.add(Padding(
          // 마지막 조작 아래에는 여백을 두지 않는다 — 왼쪽 카드 아래 끝과 단추 아래 끝이 같은 선(평가 15차 10/18).
          padding: EdgeInsets.only(bottom: ci == controls.length - 1 ? 0 : 14),
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
                KioskText(kThinqPowerOffNote,
                    textKey: ValueKey('thinq-power-off-note'),
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
              ],
            ],
          ),
        ));
      }
      if (controls.isNotEmpty && estop) {
        children.add(Row(
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
      children.add(Padding(
        padding: EdgeInsets.only(top: 6),
        child: KioskText('가전에 보내고 있어요…',
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
            Icon(Icons.info_outline, color: KioskColors.warning, size: 24),
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
                  KioskText('LG 가전으로 보내요. 바뀌었는지는 보낸 뒤 다시 봐요.',
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
                          child: const Text('닫기', style: TextStyle(fontSize: KioskType.body)),
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
