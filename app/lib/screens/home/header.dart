part of '../home_screen.dart';

class _Header extends StatelessWidget {
  const _Header({
    required this.rpiState,
    required this.backupOnly,
    required this.onVoice,
  });

  final RpiConnectionState rpiState;

  /// 서버에는 닿지 않지만 예비 연결(BLE)은 살아 있다.
  final bool backupOnly;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final (String text, Color dot) = switch (rpiState) {
      // 정상은 색을 쓰지 않는다(성공 중립 규칙) — 갈색은 주행동 색이라 정상인지 경고인지 안 읽혔다(UI 평가 10/17).
      // 상태 색 표(출시 검토 10/18, 본체와 같게): 연결됨 초록 · 끊김 노랑 · 못 씀 빨강. 라이트의 성공 중립색은 검은 점이었다.
      RpiConnectionState.connected => ('본체와 연결됨', context.appConfirmed),
      RpiConnectionState.keyRequired => ('연결 비밀번호가 필요해요', context.appWarning),
      RpiConnectionState.checking ||
      RpiConnectionState.unconfigured =>
        ('본체를 찾고 있어요', context.appMuted),
      RpiConnectionState.unreachable =>
        (backupOnly ? '블루투스로만 연결돼요' : '본체와 연결이 끊겼어요', context.appWarning),
    };
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const Key('hub-status-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpace.sm),
          Flexible(child: Text(keepWordsTogether(text), semanticsLabel: text, style: const TextStyle(fontSize: AppFont.caption))),
        ],
      ),
    );
    // 말로 하는 길 -- 누르기 어려운 사용자에게 길이 하나뿐이면 안 된다.
    // 휴리스틱 평가(10/18): 마이크 아이콘만 있어 무엇인지 몰랐다 → 짧은 글자 '말로 하기'를 함께.
    // 아이콘 아래 작은 글자(탭 막대와 같은 꼴) — 옆으로 붙이면 칩 문구가 두 줄로 꺾였다.
    final voice = Semantics(
      label: '말로 하기',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('home-voice'),
        onTap: onVoice,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mic_none_rounded, color: context.appPrimary),
              Text('말로 하기',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appPrimary, height: 1.1)),
            ]),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text('SimpleLay', style: AppText.title)),
          const SettingsAction(),
        ]),
        const SizedBox(height: AppSpace.sm),
        Wrap(spacing: AppSpace.md, runSpacing: AppSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center, children: [chip, voice]),
      ],
    );
  }
}

// ── 지금 할 일(제안 카드) ────────────────────────────────────────────────

/// 제안 한 장 — 무엇을(가전·이름), 왜 지금(이유 한 줄), 주 버튼 '지금 하기' 하나.
///
/// '지금 하기'는 **바로 누르지 않는다.** 누를 순서와 대상 가전을 보여 주는
/// 확인 화면을 연다 -- 허락은 거기서 한 번이고, 내용이 바뀌면(409)
/// 그 화면이 다시 확인하게 한다. '이번엔 안 할게요'는 글자 버튼(취소 위계).
