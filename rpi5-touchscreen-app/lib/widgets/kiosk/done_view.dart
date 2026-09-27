import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_target_line.dart';
import 'kiosk_timings.dart';

/// 실행 결과 화면.
///
/// 성공과 실패는 다르게 끝나야 한다. 성공은 확인만 하면 되니 잠시 뒤 자동으로
/// 대기 화면으로 돌아가지만, 실패는 사용자가 **무엇을 해야 하는지** 알아야
/// 하므로 자동으로 사라지지 않고 다음 행동 버튼을 제공한다 — 이전에는 둘 다
/// 3초 뒤 사라져서, 고령 사용자는 이유도 대처법도 모른 채 화면만 놓쳤다.
///
/// 이 시스템이 끝낸 것은 **버튼 조작**이다. 조리·세탁이 끝났다고 말하지 않는다.
class KioskDoneView extends StatelessWidget {
  const KioskDoneView({
    this.executionMode = 'unknown',
    super.key,
    required this.success,
    required this.label,
    this.target,
    this.reason,
    this.onRetry,
    this.onManual,
    this.onDismiss,
  });

  final String executionMode;
  String get modeLabel => executionMode == 'mock' ? '모의 실행 · 실제 조작 아님'
      : executionMode == 'real' ? '실기기 실행' : '실행 환경 미확인';

  final bool success;
  final String label;

  /// 이 실행이 대상으로 삼은 가전. 모르면 null이고 지어내지 않는다.
  final ApplianceMap? target;

  /// 실패 원인 — 문구와 권하는 행동이 달라진다. null이면 일반 실행 실패.
  final KioskFailureReason? reason;

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = success ? KioskColors.success : KioskColors.danger;
    final target = this.target;

    return ColoredBox(
      color: KioskColors.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
          child: Semantics(
            liveRegion: true,
            label: success
                ? '$label — 버튼 조작을 마쳤어요'
                : (reason ?? KioskFailureReason.execution).detail(label),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(modeLabel, style: const TextStyle(fontSize: 18, color: KioskColors.warning)),
                _ResultRing(success: success, color: color),
                const SizedBox(height: 14),
                // 가장 큰 글자가 그냥 '완료'면, 사용자는 조리나 냉방 자체가
                // 끝났다고 읽는다. 이 시스템이 끝낸 것은 **버튼 조작**이다.
                Text(
                  // 연결 유실은 정지의 증거가 아니다. 서버가 정지 결과를
                  // 반환한 경우에만 실행을 멈췄다고 표시한다.
                  success ? '버튼 조작을 마쳤어요'
                      : reason == KioskFailureReason.serverLost
                          ? '실행 상태를 확인할 수 없어요'
                          : reason == KioskFailureReason.stopped
                              ? '실행을 멈췄어요' : '버튼 조작을 확인하지 못했어요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: color,
                  ),
                ),
                if (target != null) ...[
                  const SizedBox(height: 8),
                  KioskTargetLine(appliance: target),
                ],
                const SizedBox(height: 6),
                if (success) ...[
                  // 무엇을 했는지 한 줄로 재확인하고, 어떻게 확인했는지를 말한다.
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    executionMode == 'mock' ? '모의 절차를 마쳤어요 · 실제 조작 아님'
                        : '실행기가 버튼 조작 완료를 보고했어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, color: KioskColors.muted),
                  ),
                  const SizedBox(height: 18),
                  _AutoReturn(onDismiss: onDismiss),
                ] else ...[
                  Text(
                    (reason ?? KioskFailureReason.execution).detail(label),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 22, color: KioskColors.muted),
                  ),
                  const SizedBox(height: 20),
                  _FailureActions(
                    onRetry: onRetry,
                    onManual: onManual,
                    onDismiss: onDismiss,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 실패 원인별 안내. "실행 중 문제가 발생했습니다"는 사용자가 무엇을 해야
/// 할지 알려주지 못했다 — 원인마다 다음 행동이 다르다.
enum KioskFailureReason {
  /// 버튼은 눌렀지만 센서가 눌림을 확인하지 못함(재시도 소진)
  execution,

  /// 백엔드 무응답 — 가전이 어떤 상태인지 알 수 없다
  serverLost,

  /// 긴급 정지로 멈춤 — 실패가 아니라 의도된 중단
  stopped;

  String detail(String label) => switch (this) {
        KioskFailureReason.execution =>
          '$label — 버튼이 눌렸는지 확인하지 못했어요.\n가전을 살펴본 뒤 다시 시도해주세요.',
        KioskFailureReason.serverLost =>
          'SimpleLay 본체의 실행 결과를 확인하지 못했어요.\n가전 상태를 직접 확인해주세요.',
        KioskFailureReason.stopped =>
          '$label — 실행을 멈췄어요.\n장치가 완전히 멈췄는지 확인한 뒤 다시 시도해 주세요.',
      };
}

class _ResultRing extends StatelessWidget {
  const _ResultRing({required this.success, required this.color});

  final bool success;
  final Color color;

  @override
  // 뜻을 전하는 것은 아이콘이 아니라 글자다 -- 원은 결과를 알리는 정도로만 둔다
  Widget build(BuildContext context) => Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
        ),
        child: Icon(
          success ? Icons.check : Icons.close,
          size: 38,
          color: color,
        ),
      );
}

/// 성공 후 자동 복귀를 **글자로도** 말하고, 기다리기 싫은 사람의 길을 둔다.
class _AutoReturn extends StatelessWidget {
  const _AutoReturn({required this.onDismiss});

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '잠시 후 처음 화면으로 돌아가요',
            style: const TextStyle(fontSize: 18, color: KioskColors.muted),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 220,
            height: 4,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1.0, end: 0.0),
              duration: KioskTimings.doneReturn,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 4,
                  backgroundColor: KioskColors.border,
                  valueColor: AlwaysStoppedAnimation(
                    Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: OutlinedButton(
                onPressed: onDismiss,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: KioskColors.border),
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '처음으로',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      );
}

class _FailureActions extends StatelessWidget {
  const _FailureActions({
    required this.onRetry,
    required this.onManual,
    required this.onDismiss,
  });

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRetry != null)
              _ActionButton(
                label: '다시 시도',
                icon: Icons.refresh,
                primary: true,
                onTap: onRetry!,
              ),
            if (onRetry != null && onManual != null) const SizedBox(width: 12),
            if (onManual != null)
              _ActionButton(
                label: '버튼으로 조작',
                icon: Icons.grid_view_rounded,
                primary: false,
                onTap: onManual!,
              ),
          ],
        ),
        if (onDismiss != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: KioskColors.muted,
                padding: const EdgeInsets.symmetric(horizontal: 28),
              ),
              child: const Text('닫기', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 고령 사용자 기준 터치 타깃 — 높이 60px에 넉넉한 좌우 여백
    final labelText = Text(
      label,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    );
    return SizedBox(
      height: 60,
      child: primary
          ? ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 22),
              label: labelText,
              style: ElevatedButton.styleFrom(
                backgroundColor: KioskColors.primary,
                foregroundColor: Colors.black,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 26),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 22),
              label: labelText,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFAF7F2),
                side: const BorderSide(color: KioskColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 22),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
    );
  }
}
