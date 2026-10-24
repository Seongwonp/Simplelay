import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/estop.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_text.dart';

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
    if (confirming) {
      return Material(
        key: const ValueKey('estop-banner'),
        color: KioskColors.stop,
        child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                      liveRegion: true,
                      child: KioskText(estopConfirmFor(detail),
                          style: const TextStyle(
                              color: _white,
                              fontSize: KioskType.body,
                              fontWeight: FontWeight.w700))),
                  Row(children: [
                    Expanded(
                        child: KioskText(estopTitleFor(detail),
                            style: const TextStyle(
                                color: _white,
                                fontSize: KioskType.body,
                                fontWeight: FontWeight.w800))),
                    SizedBox(
                        height: 48,
                        child: OutlinedButton(
                            key: const ValueKey('estop-cancel'),
                            onPressed: onCancel,
                            // 쓸 수 없을 때도 빨간 면 위 흰 글자(10/24 시각 QA — 기본 비활성 글자가 짙은 빨강 위에서 안 보였다).
                            style: OutlinedButton.styleFrom(
                                foregroundColor: _white,
                                disabledForegroundColor: Colors.white70,
                                side:
                                    const BorderSide(color: _white, width: 2)),
                            child: const Text('닫기',
                                style: TextStyle(fontSize: KioskType.body)))),
                    const SizedBox(width: 12),
                    SizedBox(
                        height: 48,
                        child: FilledButton(
                            key: const ValueKey('estop-confirm'),
                            onPressed: onConfirm,
                            style: _filled,
                            child: const Text(kEstopConfirmLabel,
                                style: TextStyle(fontSize: KioskType.body)))),
                  ]),
                ])),
      );
    }
    return Material(
      key: const ValueKey('estop-banner'),
      // 짙은 빨강 면에 흰 글자(7.3:1) — 긴급 정지 버튼과 같은 색으로 읽힌다.
      color: KioskColors.stop,
      // 띠 전체가 '푸는 방법 보기'와 같은 누르는 자리(휴리스틱 평가 10/18 — 오른쪽 위 작은 단추만 눌렸다). 안내를 열 뿐
      // 해제 요청은 보내지 않는다(해제는 안내 안의 '해제하기'를 눌렀을 때만).
      child: InkWell(
        key: const ValueKey('estop-banner-tap'),
        onTap: acking ? null : onRequest,
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
                    // 어절 단위 줄바꿈(평가 4차 10/18 — 실패널 글꼴이 넓어 낱말 가운데서 끊길 수 있다).
                    KioskText(
                      estopTitleFor(detail),
                      style: const TextStyle(
                          color: _white,
                          fontSize: KioskType.body,
                          fontWeight: FontWeight.w800),
                    ),
                    KioskText(
                        estopIsPowerLoss(detail)
                            ? '주변을 살펴봐 주세요'
                            : '빨간 비상 버튼을 돌려서 풀어 주세요',
                        style: const TextStyle(color: _white, fontSize: KioskType.caption)),
                    if (message != null)
                      KioskText(
                        message,
                        textKey: const ValueKey('estop-message'),
                        style: const TextStyle(
                            color: _white,
                            fontSize: KioskType.caption,
                            fontWeight: FontWeight.w700),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            // 보조 단추 높이(1920x1080에서 약 107px)·본문 글자(휴리스틱 평가 10/18 — 작은 글자 단추는 1~2 m에서 잘 안 보였다).
            SizedBox(
              height: KioskSizes.secondaryButton,
              child: FilledButton(
                key: const ValueKey('estop-ack'),
                onPressed: acking ? null : onRequest,
                style: _filled,
                child: Text(acking ? '푸는 중…' : kEstopAckLabel, maxLines: 1, softWrap: false,
                    style: const TextStyle(
                        fontSize: KioskType.body, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // 게터 — 고대비를 켜고 끄면 정지 색이 바뀐다(한 번만 만들어 두면 옛 색이 남는다).
  static ButtonStyle get _filled => FilledButton.styleFrom(
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
              shown: banner is KioskEstopBanner ||
                  KioskEstopScope.shownOf(context),
              // 평소 화면 상태 칩이 띠와 같은 말을 하도록 제목도 넘긴다(평가 4차 10/18 — 띠가 떠 있는데 칩은 '모두 정상').
              title: switch (banner) {
                final KioskEstopBanner b => estopTitleFor(b.detail),
                _ => KioskEstopScope.titleOf(context),
              },
              child: child,
            ),
          ),
        ],
      );
}

/// 아래 화면에 '위에 비상 버튼 띠가 있다'를 알린다 — 상태 띠가 얇아진다(`status_band.dart`, 2026-10-16).
/// 비상 띠는 그대로 두고(가리지 않는다) 그 아래 상태 띠만 낮춰 위쪽이 겹겹이 무거워지지 않게 한다.
class KioskEstopScope extends InheritedWidget {
  const KioskEstopScope({super.key, required this.shown, this.title, required super.child});

  final bool shown;

  /// 위 띠 제목('비상 버튼이 눌려 있어요' · '전기 플러그 전원이 꺼져 있어요'). 띠가 없으면 null.
  final String? title;

  static bool shownOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KioskEstopScope>()?.shown ??
      false;

  /// 위 띠 제목 — 띠가 없으면 null(평가 4차 10/18, 평소 화면 상태 칩이 같은 말을 한다).
  static String? titleOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<KioskEstopScope>();
    if (scope == null || !scope.shown) return null;
    return scope.title ?? kEstopTitle;
  }

  @override
  bool updateShouldNotify(KioskEstopScope oldWidget) =>
      shown != oldWidget.shown || title != oldWidget.title;
}
