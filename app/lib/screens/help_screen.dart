import 'package:flutter/material.dart';

import '../models/line_break.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// 설정 '사용 방법' — 처음 쓰는 사람이 볼 짧은 안내(휴리스틱 평가 10/18: 도움말 입구가 없었다).
///
/// 쉬운 말 다섯 토막만. 기능을 약속하지 않고 지금 앱이 하는 일만 말한다 — 누르기 전에는 늘 묻고, 멈추는 길은 셋.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const sections = <(IconData, String, String)>[
    (
      Icons.touch_app_outlined,
      '누름 장치가 버튼을 대신 눌러요',
      '본체에 달린 누름 장치가 전자레인지 같은 가전의 버튼을 대신 눌러요. 누르기 전에는 늘 무엇을 누를지 보여 주고 한 번 더 물어요.',
    ),
    (
      Icons.cloud_outlined,
      'LG 가전은 직접 바꿔요',
      '공기청정기 같은 LG 가전은 누르지 않고 LG 연결로 바로 바꿔요. 바뀐 상태를 다시 읽어 확인했을 때만 됐다고 알려요.',
    ),
    (
      Icons.front_hand_outlined,
      '멈추는 방법',
      '하는 중에는 화면 아래 실행 줄의 정지를 누르세요. 말로 "멈춰"라고 해도 되고, 본체 화면의 빨간 정지 버튼을 눌러도 돼요.',
    ),
    (
      Icons.science_outlined,
      '연습이란',
      '연습 표시가 붙은 가전과 기록은 실제 가전을 움직이지 않고 해 보는 거예요. 처음 익힐 때 마음 놓고 눌러 보세요.',
    ),
    (
      Icons.family_restroom,
      '보호자 알림이란',
      '못 한 일, 멈춘 일, 위험한 소리처럼 가족이 알아야 할 일이 생기면 이 폰에 알려요. 설정의 보호자 알림에서 볼 수 있어요.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('사용 방법')),
        // 다섯 토막뿐이라 한꺼번에 그린다 — 늘어 놓는 목록(ListView)은 화면 밖 토막을 만들지 않아 화면 읽기가 '멈추는 방법'을
        // 건너뛰었다(첫 사용 평가 2차 10/24, 접근성 트리에 없음). 토막마다 제목+본문을 한 덩어리로 읽는다.
        body: SingleChildScrollView(
          key: const Key('help-list'),
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.xxxl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, (icon, title, body)) in sections.indexed) ...[
              if (i > 0) Divider(height: AppSpace.xxxl, color: context.appBorderFaint),
              MergeSemantics(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ExcludeSemantics(child: Icon(icon, size: AppSpace.xxl, color: context.appInk)),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Semantics(
                      header: true,
                      child: Text(keepWordsTogether(title),
                          semanticsLabel: title, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(keepWordsTogether(body),
                        semanticsLabel: body, style: TextStyle(fontSize: AppFont.caption, color: context.appInk)),
                  ]),
                ),
              ])),
            ],
          ]),
        ),
      );
}
