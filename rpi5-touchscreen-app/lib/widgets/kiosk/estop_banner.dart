import 'package:flutter/material.dart';

import '../../models/estop.dart';
import '../../theme/kiosk_colors.dart';

/// 비상 버튼 걸림 전폭 경고(2026-10-05) — **모든 화면** 위쪽에 붙는다(2026-10-15, 예전에는 평소·실행·동작 중만).
///
/// 모달이 아니다: 화면을 덮지 않고 그 위에 한 줄을 차지할 뿐이라 정지 버튼은 그대로
/// 닿는다. '풀기 안내'를 누르면 같은 자리에서 안내 문장과 '취소'·'해제하기'로 바뀐다
/// — 대화창을 띄우지 않으므로 확인하는 동안에도 정지 버튼이 가려지지 않는다.
/// 해제 요청은 '해제하기'를 눌렀을 때만 나간다(자동 해제 없음).
class KioskEstopBanner extends StatelessWidget {
  const KioskEstopBanner({
    super.key,
    this.detail,
    this.confirming = false,
    this.acking = false,
    this.message,
    this.onRequest,
    this.onConfirm,
    this.onCancel,
  });

  /// 걸린 사유(서버 문장). 없으면 제목만. '다시 켜져'가 있으면 전원 꺼짐 걸림으로 말한다.
  final String? detail;

  /// 확인 문장을 보이는 중.
  final bool confirming;

  /// 해제 요청을 보내고 답을 기다리는 중.
  final bool acking;

  /// 마지막 해제 시도가 실패한 이유.
  final String? message;

  final VoidCallback? onRequest;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  static const _white = Colors.white;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    final message = this.message;
    return Material(
      key: const ValueKey('estop-banner'),
      // 짙은 빨강 면에 흰 글자(7.3:1) — 긴급 정지 버튼과 같은 색으로 읽힌다.
      color: KioskColors.stop,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        child: Row(
          children: [
            const Icon(Icons.report, color: _white, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      estopTitleFor(detail),
                      style: const TextStyle(
                          color: _white, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    if (confirming)
                      Text(
                        estopConfirmFor(detail),
                        style: const TextStyle(
                            color: _white, fontSize: 16, fontWeight: FontWeight.w700),
                      )
                    else ...[
                      if (estopDetailLine(detail) case final line?)
                        Text(line,
                            style: const TextStyle(color: _white, fontSize: 14)),
                      if (message != null)
                        Text(
                          message,
                          key: const ValueKey('estop-message'),
                          style: const TextStyle(
                              color: _white, fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (confirming) ...[
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const ValueKey('estop-cancel'),
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _white,
                    side: const BorderSide(color: _white, width: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('취소',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const ValueKey('estop-confirm'),
                  onPressed: onConfirm,
                  style: _filled,
                  child: const Text(kEstopConfirmLabel,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ),
            ] else
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const ValueKey('estop-ack'),
                  onPressed: acking ? null : onRequest,
                  style: _filled,
                  child: Text(acking ? '해제하는 중…' : kEstopAckLabel,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static final _filled = FilledButton.styleFrom(
    backgroundColor: _white,
    foregroundColor: KioskColors.stop,
    disabledBackgroundColor: Colors.white70,
    disabledForegroundColor: KioskColors.stop,
    padding: const EdgeInsets.symmetric(horizontal: 18),
  );
}

/// 경고(있으면)를 위에, 화면을 그 아래 남은 자리에 둔다 — 화면을 덮지 않는다.
class KioskEstopLayout extends StatelessWidget {
  const KioskEstopLayout({super.key, this.banner, required this.child});

  final Widget? banner;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner != null) banner!,
          Expanded(
            child: KioskEstopScope(
              shown: banner is KioskEstopBanner || KioskEstopScope.shownOf(context),
              child: child,
            ),
          ),
        ],
      );
}

/// 아래 화면에 '위에 비상 버튼 띠가 있다'를 알린다 — 상태 띠가 얇아진다(`status_band.dart`, 2026-10-16).
/// 비상 띠는 그대로 두고(가리지 않는다) 그 아래 상태 띠만 낮춰 위쪽이 겹겹이 무거워지지 않게 한다.
class KioskEstopScope extends InheritedWidget {
  const KioskEstopScope({super.key, required this.shown, required super.child});

  final bool shown;

  static bool shownOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KioskEstopScope>()?.shown ?? false;

  @override
  bool updateShouldNotify(KioskEstopScope oldWidget) => shown != oldWidget.shown;
}
