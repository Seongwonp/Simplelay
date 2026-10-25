import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// 사용 방법 한 장 — 아이콘 · 제목 · 짧은 설명.
@immutable
class KioskHelpPage {
  const KioskHelpPage({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;
}

/// 메뉴의 '사용 방법'(휴리스틱 평가 10/18 — 도움말 들어가는 곳이 없었다). 처음 쓰는 어르신 기준 쉬운 말 여섯 장
/// (UX 문구 기준 10/19): 처음 화면 → 누름 장치 → LG 가전 → 멈추기 → '확인하지 못했어요'의 뜻 → 도움 받기. 한 장에 두세 문장 —
/// 800x480 큰 글씨에서도 스크롤 없이 '다음'이 보이게 짧게 쓴다.
///
/// 사실만 말한다: 누름 장치는 버튼을 누르기 전에 묻는다(자동으로 하도록 허락한 일만 묻지 않는다), LG 가전은 누름 장치 없이 인터넷으로
/// 바꾸고 본체가 다시 읽어 바뀐 걸 볼 때만 바뀌었다고 말한다, 멈추려면 오른쪽 아래 빨간 정지. 이 화면에는 마이크가 없고 휴대폰의
/// 음성 정지는 실물 확인 전이라 넣지 않는다(10/18 결정). 버튼 이름은 화면에 적힌 그대로('메뉴'·'네'·'정지').
const kHelpPages = [
  KioskHelpPage(
    icon: Icons.home_outlined,
    title: '처음 화면에서 가전을 골라요',
    // 맨 아래 탭(시안 B 10/24)도 한마디(10/24 QA).
    body: "가전을 누르면 그 가전을 쓸 수 있어요. 화면 아래 단추로 가전·자동 실행·기록을 볼 수 있어요. 오른쪽 위 '메뉴'에 방해 금지와 설정이 있어요.",
  ),
  KioskHelpPage(
    icon: Icons.touch_app_outlined,
    title: '누름 장치가 버튼을 눌러요',
    body: "누르기 전에 먼저 물어봐요. '네'를 눌러야 버튼을 눌러요. 자동 실행을 허락한 일만 묻지 않고 해요.",
  ),
  KioskHelpPage(
    icon: Icons.wifi,
    title: 'LG 가전은 인터넷으로 조작해요',
    body: "'LG 가전'이라고 적힌 가전은 인터넷으로 조작해요. 결과를 확인하지 못하면 가전을 직접 확인해 주세요.",
  ),
  KioskHelpPage(
    icon: Icons.stop,
    title: '멈추려면 빨간 정지를 눌러 주세요',
    body: "'정지'는 움직이는 동안 오른쪽 아래에 있어요. 휴대폰 앱에서도 누를 수 있어요. 안 멈추면 가전 전원을 직접 꺼 주세요.",
  ),
  KioskHelpPage(
    icon: Icons.help_outline,
    title: '결과를 확인하지 못했을 때',
    body: '가전이 켜졌는지, 멈췄는지 확인하지 못한 상태예요. 다시 누르기 전에 가전 상태를 직접 확인해 주세요.',
  ),
  KioskHelpPage(
    icon: Icons.call_outlined,
    title: '모르면 가족에게 물어보세요',
    // 이 화면에는 자동 실행 끄기·가전 추가가 없다(설계) — 어디서 하는지 말한다(첫 사용 평가 2차 10/24). 최근 기록은 아래
    // '기록' 탭에 있다(시안 B 10/24, QA 10/24). 누구에게 물을지는 제목이 말한다 — 800x480 큰 글씨에서 '다 봤어요'가 밀리지 않게 짧게.
    body: '자동 실행 끄기·가전 추가는 휴대폰 앱에서, 최근 기록은 아래 기록 탭에서 봐요. 연기가 나면 가까이 가지 말고 119에 전화하세요.',
  ),
];

/// 사용 방법 창 — 화면 가운데 큰 카드, 한 장씩. 아래 '이전'·'다음'과 '닫기'(마지막 장에서는 '다 봤어요').
class KioskHelpGuide extends StatefulWidget {
  const KioskHelpGuide({super.key, required this.onClose, this.pages = kHelpPages});

  final VoidCallback onClose;
  final List<KioskHelpPage> pages;

  @override
  State<KioskHelpGuide> createState() => _KioskHelpGuideState();
}

class _KioskHelpGuideState extends State<KioskHelpGuide> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final page = widget.pages[_i];
    final last = _i == widget.pages.length - 1;
    final button = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, KioskSizes.secondaryButton)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.md)),
      shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(KioskSizes.buttonRadius))),
    );
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onClose,
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.6)),
        ),
      ),
      Center(
        child: Container(
          key: const ValueKey('help-guide'),
          width: 620,
          margin: const EdgeInsets.symmetric(vertical: KioskSpace.xs),
          padding: const EdgeInsets.fromLTRB(KioskSpace.lg, KioskSpace.md, KioskSpace.lg, KioskSpace.sm),
          decoration: BoxDecoration(
            color: KioskColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: KioskColors.border),
          ),
          child: SingleChildScrollView(
            child: Semantics(
              container: true,
              liveRegion: true,
              label: '사용 방법 ${widget.pages.length}장 중 ${_i + 1}장. ${page.title}. ${page.body}',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text('사용 방법 ${widget.pages.length}장 중 ${_i + 1}장',
                        key: const ValueKey('help-page-number'),
                        style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: KioskColors.ink)),
                  ),
                  const SizedBox(height: KioskSpace.xs),
                  ExcludeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(page.icon,
                            size: KioskType.status + 6,
                            color: page.icon == Icons.stop ? KioskColors.danger : KioskColors.ink),
                        const SizedBox(width: KioskSpace.sm),
                        Expanded(
                          child: KioskText(page.title,
                              textKey: const ValueKey('help-title'),
                              style: TextStyle(
                                  fontSize: KioskType.status,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                  color: KioskColors.ink)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: KioskSpace.sm),
                  ExcludeSemantics(
                    child: KioskText(page.body,
                        textKey: const ValueKey('help-body'),
                        style: TextStyle(fontSize: KioskType.status, height: 1.3, color: KioskColors.ink)),
                  ),
                  const SizedBox(height: KioskSpace.md),
                  Row(
                    children: [
                      if (_i > 0)
                        OutlinedButton(
                          key: const ValueKey('help-prev'),
                          onPressed: () => setState(() => _i--),
                          style: button.copyWith(
                            foregroundColor: WidgetStatePropertyAll(KioskColors.ink),
                            side: WidgetStatePropertyAll(BorderSide(color: KioskColors.muted, width: 2)),
                          ),
                          child: const Text('이전', style: TextStyle(fontSize: KioskType.body)),
                        ),
                      const Spacer(),
                      if (!last) ...[
                        OutlinedButton(
                          key: const ValueKey('help-close'),
                          onPressed: widget.onClose,
                          style: button.copyWith(
                            foregroundColor: WidgetStatePropertyAll(KioskColors.ink),
                            side: WidgetStatePropertyAll(BorderSide(color: KioskColors.muted, width: 2)),
                          ),
                          child: const Text('닫기', style: TextStyle(fontSize: KioskType.body)),
                        ),
                        const SizedBox(width: KioskSpace.sm),
                      ],
                      ElevatedButton(
                        key: ValueKey(last ? 'help-done' : 'help-next'),
                        onPressed: last ? widget.onClose : () => setState(() => _i++),
                        style: button.copyWith(
                          backgroundColor: WidgetStatePropertyAll(KioskColors.primary),
                          foregroundColor: WidgetStatePropertyAll(KioskColors.onAccent),
                          elevation: const WidgetStatePropertyAll(0),
                        ),
                        child: Text(last ? '다 봤어요' : '다음',
                            style: const TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
