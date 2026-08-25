import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import 'kiosk_timings.dart';

/// 실행 결과 화면.
///
/// 성공과 실패는 다르게 끝나야 한다. 성공은 확인만 하면 되니 3초 뒤 자동으로
/// 대기 화면으로 돌아가지만, 실패는 사용자가 **무엇을 해야 하는지** 알아야
/// 하므로 자동으로 사라지지 않고 다음 행동 버튼을 제공한다 — 이전에는 둘 다
/// 3초 뒤 사라져서, 고령 사용자는 이유도 대처법도 모른 채 화면만 놓쳤다.
class KioskDoneView extends StatelessWidget {
  const KioskDoneView({
    super.key,
    required this.success,
    required this.label,
    this.reason,
    this.onRetry,
    this.onManual,
    this.onDismiss,
  });

  final bool success;
  final String label;

  /// 실패 원인 — 문구와 권하는 행동이 달라진다. null이면 일반 실행 실패.
  final KioskFailureReason? reason;

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final color = success ? KioskColors.success : KioskColors.danger;
    final detail = success
        ? '$label — 모든 버튼 동작 확인됨'
        : (reason ?? KioskFailureReason.execution).detail(label);

    return ColoredBox(
      color: KioskColors.bg,
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: success ? '$label 완료되었습니다' : detail,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ResultRing(success: success, color: color),
              const SizedBox(height: 20),
              Text(
                success ? '완료' : '멈췄어요',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17, color: KioskColors.muted),
                ),
              ),
              const SizedBox(height: 24),
              if (success)
                _AutoReturnBar()
              else
                _FailureActions(
                  onRetry: onRetry,
                  onManual: onManual,
                  onDismiss: onDismiss,
                ),
            ],
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
          'SimpleLay 본체와 연결이 끊겼어요.\n가전 상태를 직접 확인해주세요.',
        KioskFailureReason.stopped =>
          '$label — 안전하게 멈췄어요.\n필요하면 다시 시도할 수 있어요.',
      };
}

class _ResultRing extends StatelessWidget {
  const _ResultRing({required this.success, required this.color});

  final bool success;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 144,
        height: 144,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.05),
          border: Border.all(color: color.withValues(alpha: 0.15), width: 1),
        ),
        child: Center(
          child: Container(
            width: 116,
            height: 116,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
              border: Border.all(
                color: color.withValues(alpha: 0.45),
                width: 2,
              ),
            ),
            child: Icon(
              success ? Icons.check : Icons.close,
              size: 54,
              color: color,
            ),
          ),
        ),
      );
}

class _AutoReturnBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
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
