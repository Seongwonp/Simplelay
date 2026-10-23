part of '../routines_screen.dart';

class SwitchWithWord extends StatelessWidget {
  const SwitchWithWord({super.key, required this.on, required this.wordKey, required this.child});

  final bool on;
  final Key wordKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          Text(on ? kSwitchOnText : kSwitchOffText,
              key: wordKey,
              style: TextStyle(
                  fontSize: AppFont.caption,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  color: on ? context.appInk : context.appMuted)),
        ],
      );
}

/// 손가락이 닿는 칸의 최소 크기(dp).
const double kMinTouch = 48;

/// 루틴 줄 오른쪽 글자 단추 — '지금 하기 >'와 '설정하기 >'가 같은 꼴(평가 11차 10/18: 글자 단추와 회색 '설정 필요' 칩이
/// 섞여 있었다). 홈 '내 루틴' 줄과 같은 글자 크기·굵기.
class RowTextAction extends StatelessWidget {
  const RowTextAction({
    super.key,
    this.actionKey,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.enabled = true,
    this.running = false,
  });

  /// 눌리는 InkWell의 키(시험이 눌림 여부를 본다).
  final Key? actionKey;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final bool enabled;
  final bool running;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        container: true,
        button: true,
        enabled: enabled,
        excludeSemantics: true,
        child: InkWell(
          key: actionKey,
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpace.sm),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (running)
                  const Padding(
                    padding: EdgeInsets.only(right: AppSpace.sm),
                    child: SizedBox(
                        width: AppSpace.lg, height: AppSpace.lg, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Text(keepWordsTogether(label),
                    semanticsLabel: label,
                    style: TextStyle(
                        fontSize: AppFont.caption,
                        fontWeight: FontWeight.w700,
                        color: enabled ? context.appInk : context.appMuted)),
                Icon(Icons.chevron_right, size: AppSpace.xl, color: context.appMuted),
              ]),
            ),
          ),
        ),
      );
}

/// 루틴 이름 옆 작은 표지 — '다음'·'자동'·'알려 드려요'. 면 없이 얇은 테두리 글자(평가 17차 10/18: 설명 줄 끝에
/// ' · 다음 · 자동'으로 이어 붙이니 가운뎃점으로 시작하는 줄이 혼자 남고, 설명이 데이터 나열처럼 보였다).
/// 설명 줄은 '매일 오후 10:00 · 공기청정기'처럼 짧게 두고, 표지는 이름 옆(자리가 모자라면 이름 아래)에 둔다.
