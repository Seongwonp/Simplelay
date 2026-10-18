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

/// 메뉴의 '사용 방법'(휴리스틱 평가 10/18 — 도움말 들어가는 곳이 없었다). 쉬운 말 세 장.
///
/// 사실만 말한다: 누름 장치는 버튼을 누르기 전에 묻는다(자동 실행을 허락한 규칙만 묻지 않는다), LG 가전은 누름 장치 없이 인터넷으로
/// 바로 바꾼다, 멈추려면 오른쪽 아래 빨간 정지. 이 화면에는 마이크가 없어 '멈춰'는 휴대폰 앱에 말한다.
const kHelpPages = [
  KioskHelpPage(
    icon: Icons.touch_app_outlined,
    title: '누름 장치가 버튼을 대신 눌러요',
    body: '전자레인지처럼 버튼이 있는 가전은 누름 장치가 버튼을 눌러 드려요. 누르기 전에 물어봐요. 자동으로 하도록 허락한 일만 묻지 않아요.',
  ),
  KioskHelpPage(
    icon: Icons.wifi,
    title: 'LG 가전은 인터넷으로 바로 바꿔요',
    body: "'LG 가전' 표시가 있는 가전은 누름 장치 없이 켜고 끌 수 있어요. 바뀌었는지는 가전을 보고 알려 주세요.",
  ),
  KioskHelpPage(
    icon: Icons.stop,
    title: '멈추려면 빨간 정지를 누르세요',
    body: "움직이는 동안에는 오른쪽 아래에 빨간 '정지'가 있어요. 휴대폰 앱의 실행 화면에서도 정지를 누를 수 있어요.",
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
              label: '사용 방법 ${_i + 1}/${widget.pages.length}. ${page.title}. ${page.body}',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text('사용 방법 ${_i + 1}/${widget.pages.length}',
                        key: const ValueKey('help-page-number'),
                        style: const TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  const SizedBox(height: KioskSpace.xs),
                  ExcludeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(page.icon,
                            size: KioskType.status + 6,
                            color: page.icon == Icons.stop ? KioskColors.danger : Colors.white),
                        const SizedBox(width: KioskSpace.sm),
                        Expanded(
                          child: KioskText(page.title,
                              textKey: const ValueKey('help-title'),
                              style: const TextStyle(
                                  fontSize: KioskType.status,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                  color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: KioskSpace.sm),
                  ExcludeSemantics(
                    child: KioskText(page.body,
                        textKey: const ValueKey('help-body'),
                        style: const TextStyle(fontSize: KioskType.status, height: 1.3, color: Colors.white)),
                  ),
                  const SizedBox(height: KioskSpace.md),
                  Row(
                    children: [
                      if (_i > 0)
                        OutlinedButton(
                          key: const ValueKey('help-prev'),
                          onPressed: () => setState(() => _i--),
                          style: button.copyWith(
                            foregroundColor: const WidgetStatePropertyAll(Colors.white),
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
                            foregroundColor: const WidgetStatePropertyAll(Colors.white),
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
                          backgroundColor: WidgetStatePropertyAll(KioskColors.neutralFill),
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
