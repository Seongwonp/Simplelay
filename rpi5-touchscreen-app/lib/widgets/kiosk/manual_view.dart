import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../models/thinq.dart';
import '../../services/kiosk_api_service.dart';
import 'kiosk_tab_bar.dart' show KioskTabBarSuppress;
import 'kiosk_text.dart';
import '../../theme/kiosk_colors.dart';
import 'appliance_art.dart';
import 'kiosk_back_button.dart';
import 'manual_actions.dart';
import 'route_badge.dart';
import 'thinq_panel.dart';

/// 내 가전(UI 확정 2026-09-30 §3-4) — 조작판 위 버튼과 내 루틴.
///
/// 멀리서도 **어느 가전의 판인지**가 먼저 읽혀야 한다. 버튼에는 등록된 라벨만
/// 쓴다 -- 내부 버튼 id는 나오지 않는다. 키오스크에는 등록 사진이 없어(사진
/// 파일은 서버에 올리지 않는다) 등록된 버튼 배치로 판을 그린다.
///
/// **승인 없이 누르지 않는다(§1-3).** 판의 버튼을 눌러도 바로 누르지 않고
/// "눌러 드릴까요?"를 한 번 묻는다. 루틴을 누르면 실행이 아니라 카드(다가오면
/// 화면)가 뜨고, 그 카드의 "시작"이 승인이다. 새 루틴은 폰 앱에서 녹화한다.
class KioskManualView extends StatefulWidget {
  const KioskManualView({
    super.key,
    required this.appliance,
    required this.onExecute,
    required this.onCancel,
    this.routines,
    this.onRoutine,
    this.applianceNames = const {},
    this.thinqRead,
    this.thinqSend,
    this.onThinqAccepted,
    this.thinqLookup,
    this.initialShowBoard = false,
  });

  /// 처음부터 버튼판을 열어 둘까 — 버튼판에서 누른 결과의 '계속 조작'은 보던 버튼판으로 돌아온다(10/24 QA).
  /// 저장된 동작에서 실행했으면 false(저장된 동작 칸으로).
  final bool initialShowBoard;

  final ApplianceMap appliance;
  final void Function(ApplianceButton button) onExecute;
  final VoidCallback onCancel;

  /// 이 가전을 다루는 내 루틴. null이면 루틴 칸을 그리지 않는다(실패 화면에서
  /// '버튼으로 조작'으로 왔을 때처럼 판만 필요한 경우).
  final List<KioskRoutine>? routines;
  final ValueChanged<KioskRoutine>? onRoutine;

  /// 가전 id → 이름 — 루틴 칸의 LG 가전 결과 말('공기청정기 켜기')에 쓴다. 이 가전의 이름은 따로 넣지 않아도 된다.
  final Map<String, String> applianceNames;

  /// ThinQ 가전 상세(2026-10-16) — 지금 상태 읽기(GET /thinq/status)·조작 보내기(POST /thinq/command)·접수됨.
  /// 읽기가 없으면(허브 없음) 상태 칸이 '연결되지 않았어요'를 말하고 조작을 내걸지 않는다.
  final Future<KioskThinqStatus> Function()? thinqRead;
  final Future<KioskJobAccepted> Function(String action, Map<String, Object> args, String clientRequestId)?
      thinqSend;
  final void Function(String jobId, String label)? onThinqAccepted;

  /// 응답을 잃은 조작의 실행 번호 찾기(GET /jobs/by-request, 검토 10/19).
  final Future<KioskRequestLookup> Function(String clientRequestId)? thinqLookup;

  @override
  State<KioskManualView> createState() => _KioskManualViewState();
}

class _KioskManualViewState extends State<KioskManualView> {
  // 누르기 전에 한 번 묻는 버튼. null이면 묻지 않는 중.
  ApplianceButton? _pending;

  // '버튼 직접 고르기'로 버튼판을 열었나(시안 B ② 10/24). 저장된 동작이 있으면 그것이 먼저다.
  late bool _showBoard = widget.initialShowBoard;

  @override
  void didUpdateWidget(KioskManualView old) {
    super.didUpdateWidget(old);
    // 가전 정의가 바뀌어 묻던 버튼이 사라졌으면 묻기를 거둔다.
    final p = _pending;
    if (p != null && !widget.appliance.buttons.any((b) => b.id == p.id)) {
      _pending = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appliance = widget.appliance;
    final routines = widget.routines;
    final pending = _pending;
    // 저장된 동작 먼저(시안 B ② 10/24) — 이 가전의 루틴이 있으면 큰 칸으로 먼저, 버튼판은 '버튼 직접 고르기' 뒤에.
    // LG 가전은 상태·조작 칸 그대로. 루틴이 없으면 버튼판을 바로 보인다.
    final hasActions = routines != null && routines.isNotEmpty && !appliance.isThinq;
    final showActions = hasActions && !_showBoard;
    final names = {...widget.applianceNames, appliance.id: appliance.displayName};
    return ColoredBox(
      color: KioskColors.bg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                // 뒤로 단추 왼쪽 끝 = 아래 버튼판 첫 칸 왼쪽 끝 = LG 가전 상태 칸 왼쪽(평가 17차 10/18 — 한 왼쪽 선).
                padding: const EdgeInsets.fromLTRB(_manualLeft, 12, 24, 6),
                child: Row(
                  children: [
                    // 뒤로가기: 아이콘 단독 히트박스는 고령 사용자가 맞추기
                    // 어렵다 — 패딩 포함 52px + 눌림 잉크 피드백
                    // 뒤로 가기 단추는 한 가지(←, 가전 선택 화면과 같게 — 2026-10-16 디자인 규격 §1-5),
                    // 흰 화살표 + '뒤로' 글자(UI 평가 4차 10/17 — 회색 화살표만으로는 1~2 m에서 잘 안 보였다).
                    // 버튼판을 '버튼 직접 고르기'로 열었으면 뒤로는 저장된 동작으로 한 단계만.
                    KioskBackButton(
                        onTap: hasActions && _showBoard ? () => setState(() => _showBoard = false) : widget.onCancel),
                    const SizedBox(width: 14),
                    // 폰과 같은 가전 그림(시안 B 10/24).
                    KioskArtTile(
                        key: const ValueKey('manual-art'),
                        category: appliance.category,
                        fallbackIcon: appliance.icon,
                        size: 56),
                    const SizedBox(width: 12),
                    // 이름과 설명은 위아래 두 줄로(2026-10-15 B10) — 한 줄에 같이 두면 둘 다 말줄임으로 잘렸다.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  // 제목은 가전 이름만(평가 17차 10/18 — '내'를 뺐다). 연습 가전은 처음 화면 타일과 같이 이름의
                                  // '(연습)'을 떼고 옆 '연습' 배지로 말한다(2차 독립 평가 A, 10/18).
                                  appliance.tileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: KioskType.status,
                                    color: KioskColors.ink,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (appliance.isPractice) ...[
                                const SizedBox(width: 12),
                                const KioskRouteBadge(key: ValueKey('manual-practice-badge'), label: '연습'),
                              ] else if (appliance.isThinq) ...[
                                const SizedBox(width: 12),
                                const KioskRouteBadge(label: 'LG 가전'),
                              ],
                            ],
                          ),
                          if (showActions)
                            Text('저장된 동작 ${routines.length}개',
                                key: const ValueKey('manual-actions-count'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted))
                          else if (!appliance.isThinq && appliance.canExecute)
                            KioskText(
                              '화면 버튼을 누르면 누름 장치가 ${appliance.displayName} 버튼을 대신 눌러요',
                              textKey: const ValueKey('manual-explain'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: KioskType.caption, color: KioskColors.muted),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                        child: showActions
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(_manualLeft, 8, 24, 16),
                                child: KioskManualActions(
                                  routines: routines,
                                  names: names,
                                  onRoutine: widget.onRoutine,
                                  onPickButtons: appliance.buttons.isEmpty ? null : () => setState(() => _showBoard = true),
                                ),
                              )
                            : _board(appliance)),
                    // ThinQ 가전은 상태·조작 두 칸이 자리를 쓴다 — 루틴 칸은 두지 않는다(2026-10-16). 저장된 동작이 있으면
                    // 그 칸이 먼저 보였으니 버튼판 옆에 다시 두지 않는다(시안 B 10/24) — 루틴이 없을 때의 안내만 남긴다.
                    // 저장된 동작에서 '버튼 직접 고르기'로 왔으면 옆 칸을 두지 않는다 — 루틴은 한 단계 뒤 칸에 있고, 빈 '내 루틴'
                    // 머리만 남으면 루틴이 없는 것처럼 읽혔다(10/24 QA). 판이 그 자리를 쓴다.
                    if (routines != null && !appliance.isThinq && !hasActions)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 20, 16),
                        child: SizedBox(
                          width: 220,
                          child: const _RoutinePanel(),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // 누르기 확인이 떠 있는 동안 아래 탭을 숨긴다(확인이 앞선다, 시안 B 10/24 ②-1).
          if (pending != null) const KioskTabBarSuppress(),
          if (pending != null)
            Positioned.fill(
              child: _PressConfirm(
                button: pending,
                applianceName: appliance.displayName,
                onConfirm: () {
                  // 다시 그리기 전에 들어온 두 번째 누름은 버린다(검토 10/19) — 요청은 하나만.
                  if (!identical(_pending, pending)) return;
                  setState(() => _pending = null);
                  widget.onExecute(pending);
                },
                onCancel: () => setState(() => _pending = null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _board(ApplianceMap appliance) {
    // ThinQ 가전에는 누를 버튼이 없다(G5). 대신 지금 상태와 큰 조작 단추(2026-10-16, 사용자 요청).
    if (appliance.isThinq) {
      return KioskThinqPanel(
        key: ValueKey('thinq-panel-${appliance.id}'),
        appliance: appliance,
        readStatus: widget.thinqRead,
        sendCommand: widget.thinqSend,
        lookupRequest: widget.thinqLookup,
        onAccepted: (jobId, label) => widget.onThinqAccepted?.call(jobId, label),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 아직 맡길 수 없는 가전이면 여기서 먼저 말한다. 눌러 보고
        // 실패로 알게 되면, 서버가 막은 것을 가전 고장으로 오해한다.
        if (!appliance.canExecute) _NotReadyNotice(appliance: appliance),
        // 이 판이 무엇인지 한 줄(휴리스틱 평가 10/18) — 칸 자리가 실제 가전 버튼 자리와 같다. 빈 칸은 점선(버튼이 없는 자리).
        Padding(
          padding: const EdgeInsets.fromLTRB(_manualLeft, 2, 24, 0),
          child: KioskText(manualLayoutNote(appliance.displayName),
              textKey: const ValueKey('manual-layout-note'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
        ),
        Expanded(
          // 남는 자리만큼 칸을 키운다. 최소는 예전 크기라, 큰 글씨·
          // 준비 안 됨 안내로 자리가 모자라면 예전처럼 스크롤된다.
          child: LayoutBuilder(
            builder: (context, box) {
              // 왼쪽 선 여백만큼 뺀 자리에서 칸 크기를 정한다(평가 17차 10/18 — 왼쪽 정렬 뒤 넘치지 않게).
              final size = _cellSizeFor(appliance, Size(box.maxWidth - (_manualLeft - _cellGap), box.maxHeight));
              // 칸이 하한 크기라 자리가 빠듯하면 왼쪽 여백을 그만큼 줄인다(넘치지 않게).
              final gridW = (appliance.cols < 1 ? 1 : appliance.cols) * (size.width + 2 * _cellGap);
              final left = (box.maxWidth - gridW).clamp(0.0, _manualLeft - _cellGap).toDouble();
              return SingleChildScrollView(
                // 판은 가운데가 아니라 위 머리 줄과 같은 왼쪽 선에서 시작한다(평가 17차 10/18).
                padding: EdgeInsets.fromLTRB(left, 6, 0, 6),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _ButtonGrid(
                    appliance: appliance,
                    cellSize: size,
                    // 준비 안 된 가전은 탭 자체를 막는다(서버도 412로 거절 —
                    // 이중 방어). 누를 수 있는데 안 되는 버튼은 두지 않는다.
                    onExecute: appliance.canExecute
                        ? (b) => setState(() => _pending = b)
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 내 루틴 칸 — 이 가전에 저장된 동작(루틴)이 **없을 때**만 버튼판 옆에 선다(시안 B 10/24 — 있으면 저장된 동작 칸이
/// 먼저 보인다, [KioskManualActions]). 새 루틴은 폰에서 만든다.
class _RoutinePanel extends StatelessWidget {
  const _RoutinePanel();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('내 루틴',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
          const SizedBox(height: 8),
          Expanded(
            child: KioskText(
              '이 가전에는 아직 루틴이 없어요',
              style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
            ),
          ),
          const SizedBox(height: 8),
          // 판의 버튼은 하나씩 묻고 하나씩 누른다 — '30초 → 시작'처럼 여러 개를 한 번 묻고 한 번에 맡기는 길은 루틴이다
          // (첫 사용 검토 10/19 #6). 새 루틴은 폰에서 만든다.
          KioskText(
            '여러 버튼을 한 번에 누르려면 휴대폰 앱에서 루틴을 만들 수 있어요',
            style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
          ),
        ],
      );
}

/// 판의 버튼을 누르기 전 한 번 묻는다 — 누르는 순간 실물 가전이 움직인다.
class _PressConfirm extends StatelessWidget {
  const _PressConfirm({
    required this.button,
    required this.applianceName,
    required this.onConfirm,
    required this.onCancel,
  });

  final ApplianceButton button;
  final String applianceName;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  // 화면 읽기에도 창이다(첫 사용 검토 10/19 #17) — 색만 덮으면 창 뒤 판 버튼까지 읽혀 눌렸다.
  // 이름 있는 한 화면으로 읽히고, 처음 머무는 곳은 실물을 움직이지 않는 '그만두기'.
  @override
  Widget build(BuildContext context) => BlockSemantics(
        child: Semantics(
          key: const ValueKey('manual-press-confirm'),
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: "'${button.label}' 버튼을 누를까요?",
          child: _box(),
        ),
      );

  Widget _box() => ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Center(
          child: Container(
            width: 460,
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
            decoration: BoxDecoration(
              color: KioskColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: KioskColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KioskText(
                  "'${button.label}' 버튼을 누를까요?",
                  style: TextStyle(
                    fontSize: KioskType.status,
                    fontWeight: FontWeight.w700,
                    color: KioskColors.ink,
                  ),
                ),
                const SizedBox(height: 8),
                // 누르면 무엇이 일어나는지 한 줄(휴리스틱 평가 10/18) — 화면 칸이 아니라 실제 가전 버튼을 누름 장치가 누른다.
                KioskText(
                  manualPressNote(applianceName, button.label),
                  textKey: const ValueKey('manual-press-note'),
                  style: TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.muted),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        autofocus: true,
                        onPressed: onCancel,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 60),
                          foregroundColor: KioskColors.ink,
                          side: BorderSide(color: KioskColors.border),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('닫기',
                            style: TextStyle(
                                fontSize: KioskType.body, fontWeight: FontWeight.w500)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: ElevatedButton(
                        onPressed: onConfirm,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 60),
                          backgroundColor: KioskColors.primary,
                          foregroundColor: KioskColors.onAccent,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('누르기',
                            style: TextStyle(
                                fontSize: KioskType.body, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}

/// 준비가 끝나지 않은 가전임을 큰 글씨로 알린다.
///
/// 상태 이름만 말하지 않고 **무엇이 남았는지**를 함께 낸다 — 폰과 같은
/// 문장을 쓴다(한 서버에서 나온 값이다).
class _NotReadyNotice extends StatelessWidget {
  const _NotReadyNotice({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) {
    final disconnected = appliance.readiness == 'disconnected';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: KioskColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            disconnected ? Icons.link_off : Icons.build_outlined,
            color: KioskColors.warning,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KioskText(
                  disconnected ? '아직 연결되지 않았어요' : '아직 준비가 끝나지 않았어요',
                  style: TextStyle(
                    fontSize: KioskType.body,
                    fontWeight: FontWeight.w700,
                    color: KioskColors.ink,
                  ),
                ),
                if (appliance.readinessReasons.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  KioskText(
                    appliance.readinessReasons.join(' · '),
                    style: TextStyle(
                      fontSize: KioskType.caption,
                      color: KioskColors.muted,
                    ),
                  ),
                ],
                // 사유마다 할 일 한 줄(2026-10-15 §4) — '안 됩니다'로 끝내지 않는다.
                if (readinessTodo(appliance) case final todo?) ...[
                  const SizedBox(height: 6),
                  KioskText(
                    todo,
                    textKey: const ValueKey('readiness-todo'),
                    style: TextStyle(fontSize: KioskType.body, color: KioskColors.ink),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 준비 안 됨 사유(서버 `readiness.py` 문장) → 사람이 할 일 한 줄. 모르는 사유면 null(지어내지 않는다).
/// 서버 문장이 조금 바뀌어도 맞도록 핵심 낱말로 고른다(옛 '좌표'·새 '자리' 모두).
String? readinessTodo(ApplianceMap appliance) {
  final reasons = appliance.readinessReasons.join(' ');
  if (appliance.readiness == 'disconnected' || reasons.contains('연결되지 않았')) {
    return '처음 화면 위쪽 연결 표시를 눌러 봐 주세요';
  }
  if (reasons.contains('좌표') ||
      reasons.contains('자리') ||
      reasons.contains('보정') ||
      reasons.contains('오래돼')) {
    return '휴대폰 앱에서 이 가전의 버튼 자리를 맞춰 주세요';
  }
  if (reasons.contains('모터') || reasons.contains('센서')) {
    return '잠시 기다려 주세요. 계속되면 누름 장치를 다시 켜 주세요';
  }
  return null;
}

/// 판이 차지할 수 있는 자리에서 칸 하나의 크기.
///
/// 아래로는 예전 고정 크기(멀리서 읽히는 하한), 위로는 상한을 둔다 -- 칸이
/// 끝없이 커지면 한눈에 판 전체가 들어오지 않고 손을 크게 옮겨야 한다.
///
/// 누를 수 없는 판(준비 안 됨)은 손 닿는 크기 하한이 필요 없다 — 판 전체가 한 화면에 보이게 더 줄인다(10/24 시각 QA —
/// 준비 안내 아래에서 마지막 줄이 잘려 있었다).
Size _cellSizeFor(ApplianceMap appliance, Size area) {
  const gap = _cellGap * 2;
  final cols = appliance.cols < 1 ? 1 : appliance.cols;
  final rows = appliance.rows < 1 ? 1 : appliance.rows;
  // 아래 탭 줄이 선 뒤(시안 B 10/24)에는 4행 판이 예전 하한(66)으로 들어가지 않아 맨 아래 줄(취소·시작)이 탭 줄 뒤로
  // 밀려 잘렸다(10/24 QA). 자리가 모자라면 손 닿는 하한([_cellHeightTight], 캔버스 48 이상)까지 줄여 판 전체가 보이게 한다.
  final minH = appliance.canExecute ? _cellHeightTight : _cellHeightDisabled;
  final w = ((area.width - 48) / cols - gap).clamp(_cellWidth, _cellMaxWidth);
  final h = ((area.height - 12) / rows - gap).clamp(minH, _cellMaxHeight);
  return Size(w.toDouble(), h.toDouble());
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({
    required this.appliance,
    required this.cellSize,
    required this.onExecute,
  });

  final ApplianceMap appliance;
  final Size cellSize;

  /// null이면 이 가전은 아직 맡길 수 없다.
  final void Function(ApplianceButton)? onExecute;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(appliance.rows, (row) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(appliance.cols, (col) {
            final btn = appliance.buttonAt(col, row);
            return Padding(
              padding: const EdgeInsets.all(_cellGap),
              child: btn == null
                  // 버튼이 없는 자리 — 빈 칸(폰과 같다). 점선 칸(출시 검토 10/18)도, 흐린 '버튼 없음' 글자(첫 사용 평가 3차
                  // 10/24 — 칸마다 되풀이돼 단추처럼 읽혔다)도 두지 않는다. 칸 자리는 남겨 실제 가전 버튼 자리와 같게 둔다.
                  // 화면 읽기에는 원래 말하지 않던 자리다(낭독 없음).
                  ? SizedBox(
                      key: ValueKey('manual-empty-$col-$row'),
                      width: cellSize.width,
                      height: cellSize.height,
                    )
                  : _ButtonCell(
                      key: ValueKey('manual-cell-${btn.label}'),
                      button: btn,
                      size: cellSize,
                      onTap: onExecute == null
                          ? null
                          : () => onExecute!(btn),
                    ),
            );
          }),
        );
      }),
    );
  }
}

/// 버튼판 위 한 줄 — '전자레인지 버튼 자리 그대로예요'(휴리스틱 평가 10/18).
String manualLayoutNote(String applianceName) => '실제 $applianceName 버튼과 같은 배치예요';

/// 누르기 확인 창의 한 줄 — '누르면 누름 장치가 전자레인지 즉석밥 버튼을 눌러요'.
String manualPressNote(String applianceName, String buttonLabel) =>
    '누르면 누름 장치가 $applianceName $buttonLabel 버튼을 눌러요';


// 멀리서 읽히는 하한. 4열(인덕션)·4행(전자레인지)이 800x480에 들어가는 크기였다.
const double _cellWidth = 124;
// 자리가 모자랄 때의 하한 — 누르는 자리 48 이상(접근성 터치 크기), 글자 한 줄이 들어간다.
const double _cellHeightTight = 52;
const double _cellHeightDisabled = 40;

// 칸이 커질 수 있는 상한(설계 캔버스 기준).
// 폭 상한은 3열 판이 화면 폭을 고르게 쓰는 값(결선 모의 평가 10/18 — 200이면 오른쪽 25%가 비었다). 루틴 칸이 있으면
// 자리가 좁아 이 상한에 닿지 않는다.
const double _cellMaxWidth = 260;
const double _cellMaxHeight = 96;
const double _cellGap = 5;

/// 수동 화면의 왼쪽 선 — 뒤로 단추·버튼판 첫 칸·LG 가전 상태 칸(그 패널 안쪽 여백 24와 같다).
const double _manualLeft = 24;

class _ButtonCell extends StatelessWidget {
  const _ButtonCell({
    super.key,
    required this.button,
    required this.size,
    required this.onTap,
  });

  final ApplianceButton button;
  final Size size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // InkWell 잉크 피드백 — "눌렸는지 모름"이 실제 물리 버튼을 누르는 앱에선
    // 오조작(연타)으로 이어진다. Material 트리가 없는 화면이라 transparency로 공급.
    final enabled = onTap != null;
    final cell = Container(
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          // 못 누르는 칸은 바탕과 같은 색(떠 있는 단추처럼 보이지 않게) — 폰의 흐린 판과 같은 뜻(10/24 QA).
          color: enabled ? KioskColors.surface : KioskColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KioskColors.border),
        ),
        child: enabled
            ? Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(10),
                  splashColor: KioskColors.primary.withValues(alpha: 0.25),
                  highlightColor: KioskColors.primary.withValues(alpha: 0.12),
                  child: label,
                ),
              )
            : label,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: '${button.label} 버튼 누르기',
      excludeSemantics: true,
      // 준비 안 된 판은 칸 전체를 흐리게(10/24 QA — 글자만 흐려서는 누를 수 있는 단추처럼 보였다). 폰 판과 같은 0.45 근처,
      // 글자는 진한 색 그대로 두어 흐린 뒤에도 읽힌다.
      child: enabled ? cell : Opacity(opacity: 0.5, child: cell),
    );
  }

  Widget get label => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: KioskText(
                  button.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // 칸이 넉넉해지면 글자도 함께 키운다.
                    fontSize: size.height >= 80 ? 24 : 20,
                    height: 1.15,
                    // 못 누르는 칸은 칸 전체를 흐린다(위 Opacity) — 글자까지 흐린 색이면 겹쳐서 읽히지 않는다(10/24 시각 QA —
                    // 흐린 글자도 3:1 이상).
                    color: KioskColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
}

