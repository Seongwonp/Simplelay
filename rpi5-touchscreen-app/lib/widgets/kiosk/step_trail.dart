import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 누를 순서 한 칸의 상태.
enum KioskStepState {
  /// 작은 팔이 눌렀다고 알려 왔다(가전이 켜졌다는 뜻이 아니다 — 버튼판의 ✓와 같은 뜻).
  done,

  /// 눌렀는지 모른다.
  unknown,

  /// 지금 누르는 칸.
  current,

  /// 아직 누르지 않은 칸(이름은 서버가 미리 주지 않아 번호만).
  todo,
}

/// 누를 순서 한 칸 — 이름을 모르면 null(지어내지 않는다).
typedef KioskStep = ({String? label, KioskStepState state});

/// 누를 순서 줄(평가 7차 10/18) — 실행·결과 화면 왼쪽 아래 빈자리에 '✓ 즉석밥 — ② 시작'처럼 순서를 크게.
///
/// 예전에는 왼쪽 아래 약 40%가 빈 검정이라 모든 실행 화면이 같은 틀을 찍은 것처럼 보였다. 진행 정보(끝낸 수·전체 수·
/// 누른 이름)가 있을 때만 그린다 — 두 칸 미만이거나 [maxSteps]를 넘으면 그리지 않는다(위 '누를 버튼 N개 중 K번째'가 말한다).
/// 화면 읽기는 위 상태 영역이 같은 말을 하므로 읽지 않는다. 키는 칸마다 `step-<i>-<상태>`.
class KioskStepTrail extends StatelessWidget {
  const KioskStepTrail({super.key, required this.steps, this.title, this.caution = false});

  final List<KioskStep> steps;

  /// 줄 위 작은 제목('누른 순서'). 없으면 두지 않는다.
  final String? title;

  /// 지금 칸을 주의색으로(자리를 맞춰 다시 누르는 중).
  final bool caution;

  static const int maxSteps = 6;

  /// 이 줄을 그릴 만한가.
  static bool worth(int count) => count >= 2 && count <= maxSteps;

  static const double _dot = 48;
  static const double _gap = 28;
  static const double _maxCell = 132;

  @override
  Widget build(BuildContext context) {
    if (!worth(steps.length)) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title case final t?) ...[
            Text(t,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
            const SizedBox(height: KioskSpace.xs),
          ],
          LayoutBuilder(builder: (context, box) {
            final n = steps.length;
            final cell = ((box.maxWidth - (n - 1) * _gap) / n).clamp(_dot, _maxCell).toDouble();
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0)
                    // 칸 사이 잇는 선 — 동그라미 가운데 높이.
                    Padding(
                      padding: const EdgeInsets.only(top: _dot / 2 - 1.5),
                      child: Container(
                          width: _gap,
                          height: 3,
                          color: steps[i - 1].state == KioskStepState.done
                              ? KioskColors.muted
                              : KioskColors.border),
                    ),
                  SizedBox(width: cell, child: _Cell(index: i, step: steps[i], caution: caution)),
                ],
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.index, required this.step, required this.caution});

  final int index;
  final KioskStep step;
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final s = step.state;
    final currentColor = caution ? KioskColors.warning : KioskColors.running;
    final (Color fill, Color border, Widget mark) = switch (s) {
      KioskStepState.done => (
          KioskColors.neutralFill,
          KioskColors.neutralFill,
          Icon(Icons.check, size: 30, color: KioskColors.onAccent)
        ),
      KioskStepState.unknown => (
          Colors.transparent,
          KioskColors.warning,
          Icon(Icons.question_mark, size: 28, color: KioskColors.warning)
        ),
      KioskStepState.current => (currentColor, currentColor, _num(index, KioskColors.onAccent)),
      KioskStepState.todo => (Colors.transparent, KioskColors.muted, _num(index, KioskColors.muted)),
    };
    final label = step.label;
    return Column(
      key: ValueKey('step-$index-${s.name}'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: KioskStepTrail._dot,
          height: KioskStepTrail._dot,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 3),
          ),
          child: mark,
        ),
        const SizedBox(height: 6),
        Text(
          label ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: KioskType.body,
            height: 1.2,
            fontWeight: s == KioskStepState.current ? FontWeight.w800 : FontWeight.w600,
            color: s == KioskStepState.current ? Colors.white : KioskColors.muted,
          ),
        ),
      ],
    );
  }

  static Widget _num(int i, Color color) => Text('${i + 1}',
      textScaler: TextScaler.noScaling,
      style: TextStyle(
          fontSize: KioskType.body, height: 1, fontWeight: FontWeight.w800, color: color));
}
