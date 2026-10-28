// 키오스크 디자인 토큰(2026-10-16) — docs/키오스크-디자인-규격-계획-2026-10-15.md §1의 출발값을 코드 한 곳에 둔다.
//
// 모든 수치는 **800x480 설계 캔버스 단위**다. 15.8형(1920x1080)에서는 KioskCanvas가 2.05배로 키운다
// (가장자리 여백 좌우 140·위아래 48px은 §4 결정대로 그대로 둔다). 규격 문서의 px 값 = 캔버스 값 × 2.05.
// 연구로 검증한 값이 아니라 시안 출발값이다 — 실패널 1.5 m·3 m에서 보고 고친다.
import 'package:flutter/material.dart';

/// 글자 크기 4단계(§1-3). 대기 시계(220px)만 예외이고 그 밖의 크기는 이 넷으로만 쓴다.
class KioskType {
  const KioskType._();

  /// 핵심 — 결과 제목, 제안 질문, 지금 누르는 버튼(규격 80~96px → 82px).
  static const double key = 40;

  /// 상태 — 상태 제목, 할 일 한 줄, 주요 단추 글자(규격 56~64px → 61.5px).
  static const double status = 30;

  /// 본문 — 설명, 근거(규격 40~44px → 43px).
  static const double body = 21;

  /// 보조 — 캡션, 카운트다운, 띠 아래 작은 글(규격 32~36px → 35px).
  static const double caption = 17;
}

/// 간격 5단계(UI 개편안 10/17 §5 — 8·12·20·28·36). 여백·사이 간격은 이 다섯으로만 쓴다.
class KioskSpace {
  const KioskSpace._();

  /// 붙어 있는 것(아이콘과 글자, 제목과 그 아래 한 줄).
  static const double xs = 8;

  /// 같은 묶음 안의 줄 사이.
  static const double sm = 12;

  /// 묶음과 묶음 사이.
  static const double md = 20;

  /// 화면 영역 사이(왼쪽 글 칸과 오른쪽 그림 칸).
  static const double lg = 28;

  /// 화면 가장자리 여백(좌우).
  static const double xl = 36;
}

/// 크기·자리 토큰.
class KioskSizes {
  const KioskSizes._();

  // 정지 영역(§1-1) — 실행·정지 대기·정지 미확인 세 화면에서 같은 자리·같은 크기
  /// 정지 단추 폭·높이(1920x1080에서 약 558x197px — 규격 560x200).
  static const double stopWidth = 272;
  static const double stopHeight = 96;

  /// 화면 오른쪽·아래에서 정지 단추까지(캔버스). 실제 화면에서는 가장자리 여백을 더해
  /// 오른쪽 약 181px·아래 약 73px — 규격 '64 이상'.
  static const double stopRight = 20;
  static const double stopBottom = 12;

  /// 정지 영역 옆 다른 조작과의 간격(규격 48px 이상 → 28 = 57px).
  static const double stopGap = 28;

  /// 정지 단추 테두리(색을 빼도 다른 단추와 구분되게).
  static const double stopBorder = 3;

  /// 정지 단추 아이콘(■ 하나).
  static const double stopIcon = 40;

  // 상태 띠(§1-2) — 제안·실행·정지 대기·결과에 같은 위치·같은 높이
  /// 띠 높이(1920x1080에서 82px — 규격 48~88). 보통 글씨에서는 이 높이로 고정되고, 큰 글씨에서
  /// 글이 넘치면 줄을 바꿔 늘어난다(글자를 줄이지 않는다).
  static const double bandHeight = 40;

  /// 띠 왼쪽 색 줄 두께.
  static const double bandStripe = 6;
  static const double bandIcon = 24;

  /// 띠 면의 옅기 — 채운 단추(주요 행동)처럼 보이지 않게 색은 줄·아이콘으로 싣는다.
  static const double bandTint = 0.22;

  /// 비상 버튼 띠가 위에 있을 때의 얇은 상태 띠(2026-10-16 큰 글자 단계) — 진한 빨강 비상 띠 + 상태 띠 +
  /// 상태 제목이 쌓여 위가 무거웠다. 두 뜻(비상 · 지금 단계)은 그대로 보이고 상태 띠만 낮게(1920x1080에서 약 53px).
  static const double bandSlimHeight = 26;
  static const double bandSlimIcon = 18;

  /// 설명 그림(버튼판)이 이보다 낮으면 위 안내 글을 접고 칸에 자리를 준다(비상 버튼 풀기 안내처럼 위 띠가
  /// 길어질 때 그림이 아주 작아졌다, 2026-10-16 골든 `hold_estop_confirm`).
  static const double panelCaptionMinHeight = 200;

  // 상태 영역(§1-2) — 실행 계열 화면 왼쪽 위 같은 기준선
  /// 상태 아이콘(규격 96~120px → 48 = 98px).
  static const double statusIcon = 48;

  /// 실행 계열 화면 내용 여백(왼쪽·위). 오른쪽·아래는 정지 영역 값을 쓴다.
  static const double runLeft = 36;
  static const double runTop = 12;

  // 단추(§1-5)
  /// 주 단추(채움) 높이 — 규격 144~152px → 72 = 148px.
  static const double primaryButton = 72;

  /// 보조 단추(테두리) 높이 — 규격 96~112px → 52 = 107px.
  static const double secondaryButton = 52;

  static const double buttonRadius = 12;

  // 결과 화면(§1-7)
  /// 결과 아이콘 원(규격 200px → 88 = 180px, 세로 자리가 모자라 출발값보다 조금 작게).
  static const double resultIcon = 88;

  /// 큰 글자에서 결과 아이콘 원 — 제목·할 일이 먼저 보이도록 줄인다(§1-8, 1920x1080에서 약 115px).
  static const double resultIconLarge = 56;

  /// 결과 제목 최대 폭(규격 1,100~1,400px → 660 = 1,353px).
  static const double resultMaxWidth = 660;

  /// 하단 단추 영역 아래 여백(가장자리 여백 48px과 더해 약 73px — 규격 64).
  static const double actionsBottom = 12;
}

/// 큰 글자 배치(§1-8) — 설정의 큰 글씨(kiosk_screen이 1.22배 textScaler를 얹는다)일 때 가로 2열 배치를
/// 세로 1열로 바꾼다. 문장을 한 줄에 억지로 넣지 않고 글은 자연스럽게 여러 줄로 둔다. 정지 단추는 같은 자리·크기.
class KioskLayout {
  const KioskLayout._();

  /// 큰 글씨인가(평소 화면 `idle_view`와 같은 기준).
  static bool isLarge(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(10) > 10.5;
}

/// 단추 모양 두 가지(§1-5) — 주 단추(앰버 채움, 화면당 하나)와 보조 단추(테두리). 글자만 있는 조작은 두지 않는다.
class KioskButtons {
  const KioskButtons._();

  static ButtonStyle primary({required Color background, required Color foreground}) =>
      ElevatedButton.styleFrom(
        minimumSize: const Size(0, KioskSizes.primaryButton),
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KioskSizes.buttonRadius)),
      );

  static ButtonStyle secondary({required Color foreground, required Color border}) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(0, KioskSizes.secondaryButton),
        foregroundColor: foreground,
        side: BorderSide(color: border, width: 2),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KioskSizes.buttonRadius)),
      );
}
