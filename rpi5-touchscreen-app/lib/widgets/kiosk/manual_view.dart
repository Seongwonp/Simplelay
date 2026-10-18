import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/ambient.dart';
import '../../models/appliance.dart';
import '../../models/thinq.dart';
import '../../services/kiosk_api_service.dart';
import 'kiosk_text.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_back_button.dart';
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
  });

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
  final Future<KioskJobAccepted> Function(String action, Map<String, Object> args)? thinqSend;
  final void Function(String jobId, String label)? onThinqAccepted;

  @override
  State<KioskManualView> createState() => _KioskManualViewState();
}

class _KioskManualViewState extends State<KioskManualView> {
  // 누르기 전에 한 번 묻는 버튼. null이면 묻지 않는 중.
  ApplianceButton? _pending;

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
                    KioskBackButton(onTap: widget.onCancel),
                    const SizedBox(width: 14),
                    Icon(appliance.icon, color: KioskColors.muted, size: 30),
                    const SizedBox(width: 10),
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
                                  // 제목은 가전 이름만(평가 17차 10/18 — '내'를 뺐다).
                                  appliance.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: KioskType.status,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (appliance.isThinq) ...[
                                const SizedBox(width: 12),
                                const KioskRouteBadge(label: 'LG 가전'),
                              ],
                            ],
                          ),
                          if (!appliance.isThinq && appliance.canExecute)
                            KioskText(
                              '화면 버튼을 누르면 작은 팔이 ${appliance.name} 버튼을 대신 눌러요',
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
                    Expanded(child: _board(appliance)),
                    // ThinQ 가전은 상태·조작 두 칸이 자리를 쓴다 — 루틴 칸은 두지 않는다(2026-10-16).
                    if (routines != null && !appliance.isThinq)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 20, 16),
                        child: SizedBox(
                          width: 220,
                          child: _RoutinePanel(
                            routines: routines,
                            names: {...widget.applianceNames, appliance.id: appliance.name},
                            onRoutine: widget.onRoutine,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (pending != null)
            Positioned.fill(
              child: _PressConfirm(
                button: pending,
                onConfirm: () {
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
        onAccepted: (jobId, label) => widget.onThinqAccepted?.call(jobId, label),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 아직 맡길 수 없는 가전이면 여기서 먼저 말한다. 눌러 보고
        // 실패로 알게 되면, 서버가 막은 것을 가전 고장으로 오해한다.
        if (!appliance.canExecute) _NotReadyNotice(appliance: appliance),
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

/// 내 루틴 칸 — 이 가전을 다루는 루틴. 누르면 카드(승인)로 간다.
class _RoutinePanel extends StatelessWidget {
  const _RoutinePanel({required this.routines, required this.names, required this.onRoutine});

  final List<KioskRoutine> routines;
  final Map<String, String> names;
  final ValueChanged<KioskRoutine>? onRoutine;

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
            child: routines.isEmpty
                ? KioskText(
                    '이 가전에는 아직 루틴이 없어요',
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: routines.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = routines[i];
                      final size = r.sizeLabelWith(names);
                      return Material(
                        color: KioskColors.surface2,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          key: ValueKey('routine-${r.id}'),
                          onTap: onRoutine == null ? null : () => onRoutine!(r),
                          borderRadius: BorderRadius.circular(12),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 56),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              // 이름 위, 크기('누를 버튼 3개') 아래 — 옆에 붙이면 좁은 칸에서 '버튼 3|번'처럼 숫자와 단위가
                              // 갈라졌다(평가 4차 10/18). 둘 다 어절 단위로 줄을 바꾼다.
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  KioskText(
                                    r.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: KioskType.body,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                  if (size.isNotEmpty)
                                    KioskText(
                                      size,
                                      style: TextStyle(
                                          fontSize: KioskType.caption, color: KioskColors.muted),
                                    ),
                                  // 누르면 한다는 표시(평가 8차 10/18) — 폰 루틴 줄과 같은 말. 누르면 바로 하지 않고 확인 카드가 먼저 뜬다.
                                  if (onRoutine != null)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Text('지금 하기 ›',
                                          maxLines: 1,
                                          softWrap: false,
                                          style: TextStyle(
                                              fontSize: KioskType.caption,
                                              fontWeight: FontWeight.w700,
                                              color: KioskColors.primary)),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          KioskText(
            '새 루틴은 휴대폰 앱에서 만들어요',
            style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
          ),
        ],
      );
}

/// 판의 버튼을 누르기 전 한 번 묻는다 — 누르는 순간 실물 가전이 움직인다.
class _PressConfirm extends StatelessWidget {
  const _PressConfirm({
    required this.button,
    required this.onConfirm,
    required this.onCancel,
  });

  final ApplianceButton button;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ColoredBox(
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
                  "'${button.label}' 버튼을 눌러 드릴까요?",
                  style: const TextStyle(
                    fontSize: KioskType.status,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        onPressed: onCancel,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 60),
                          foregroundColor: Colors.white,
                          side: BorderSide(color: KioskColors.border),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('그만두기',
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
                  style: const TextStyle(
                    fontSize: KioskType.body,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
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
                    style: const TextStyle(fontSize: KioskType.body, color: Colors.white),
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
    return '휴대폰 앱에서 이 가전 버튼 자리 맞추기를 해 주세요';
  }
  if (reasons.contains('모터') || reasons.contains('센서')) {
    return '잠시 기다려 주세요. 계속되면 작은 팔을 다시 켜 주세요';
  }
  return null;
}

/// 판이 차지할 수 있는 자리에서 칸 하나의 크기.
///
/// 아래로는 예전 고정 크기(멀리서 읽히는 하한), 위로는 상한을 둔다 -- 칸이
/// 끝없이 커지면 한눈에 판 전체가 들어오지 않고 손을 크게 옮겨야 한다.
Size _cellSizeFor(ApplianceMap appliance, Size area) {
  const gap = _cellGap * 2;
  final cols = appliance.cols < 1 ? 1 : appliance.cols;
  final rows = appliance.rows < 1 ? 1 : appliance.rows;
  final w = ((area.width - 48) / cols - gap).clamp(_cellWidth, _cellMaxWidth);
  final h = ((area.height - 12) / rows - gap).clamp(_cellHeight, _cellMaxHeight);
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
                  ? SizedBox.fromSize(size: cellSize)
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

// 멀리서 읽히는 하한. 4열(인덕션)·4행(전자레인지)이 800x480에 들어가는 크기였다.
const double _cellWidth = 124;
const double _cellHeight = 66;

// 칸이 커질 수 있는 상한(설계 캔버스 기준).
const double _cellMaxWidth = 200;
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
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '${button.label} 버튼 누르기',
      excludeSemantics: true,
      child: Container(
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KioskColors.border),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            splashColor: KioskColors.primary.withValues(alpha: 0.25),
            highlightColor: KioskColors.primary.withValues(alpha: 0.12),
            child: Center(
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
                    // 못 누르는 버튼은 그렇게 보여야 한다 — 색만 같으면
                    // 눌리지 않는 이유를 가전 쪽에서 찾게 된다.
                    color: onTap == null
                        ? const Color(0xFFFAF7F2).withValues(alpha: 0.35)
                        : const Color(0xFFFAF7F2),
                    fontWeight: FontWeight.w600,
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
