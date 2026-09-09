/// 팔레트 조합의 명도 대비를 고정한다.
///
/// 왜 테스트로 박아두나: 색은 "예뻐 보이는지"로 판단하게 되고, 대비 미달은 눈으로
/// 잘 안 잡힌다. 실제로 이 앱에서 가장 중요한 버튼 둘(제안 승인·긴급 정지)이 각각
/// 2.25:1, 3.63:1이었다 — 채도 있는 색 위에 흰 글자를 얹었기 때문이다. 검정이면
/// 9.34:1, 5.78:1이다.
///
/// 캡션 쪽은 더 얄궂었다. AppText.caption이 **다크용 회색을 상수로** 물고 있어서
/// 라이트 모드 바탕 위에서 2.48:1이었다. app_colors.dart에 "하드코딩하면
/// 밝은 바탕에서 안 보인다"는 주석이 이미 있었는데 타이포 토큰 자신이 그걸 어겼다.
///
/// 2026-09-09에 팔레트를 크림+골드에서 흰 계열 바탕+인디고로 바꿨다. 아래
/// 단정은 전부 **토큰**을 참조하므로 값이 바뀌어도 그대로 유효하다 -- 그게
/// 색을 상수로 흩뿌리지 않고 토큰에 모아둔 이유다.
///
/// 주 사용자가 고령자라 접근성은 요구사항이지 장식이 아니다. 기준은 WCAG AA
/// 일반 텍스트 4.5:1.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/theme/app_colors.dart';

/// WCAG 상대 휘도.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA — 일반 텍스트
const _aa = 4.5;

/// 이 제품의 목표. 고령 사용자가 주 사용자라 AA로는 부족하다고 보고 AAA(7:1)를
/// **본문·보조 텍스트에** 적용한다. 상태를 알리는 채도색까지 7:1로 끌어올리면
/// 색이 전부 탁해져서, 그쪽은 AA를 유지하고 색 외의 단서(아이콘·문구)를 함께 둔다.
const _aaa = 7.0;

void main() {
  group('채도 있는 색을 면으로 쓸 때는 onAccent 글자', () {
    // 흰 글자로 되돌리면 전부 실패한다 — 그게 이 테스트의 목적이다
    for (final entry in <String, Color>{
      '강조색(주요 실행)': AppColors.primary,
      '세이지 그린(성공·승인)': AppColors.success,
      '브릭 레드(정지·삭제)': AppColors.danger,
      '앰버(경고)': AppColors.warning,
    }.entries) {
      test('${entry.key} 배경 + onAccent', () {
        expect(contrast(entry.value, AppColors.onAccent), greaterThanOrEqualTo(_aa));
      });
    }

    test('흰 글자는 실제로 미달이다 (회귀 방지의 근거)', () {
      // 이 기대가 깨진다면 팔레트가 밝아진 것이므로 onAccent 규칙을 재검토할 것
      expect(contrast(AppColors.success, Colors.white), lessThan(_aa));
      expect(contrast(AppColors.danger, Colors.white), lessThan(_aa));
    });
  });

  group('보조 텍스트는 AAA(7:1)까지', () {
    // 캡션은 카드 표면뿐 아니라 스캐폴드 배경에도 얹힌다 — 둘 다 통과해야 한다.
    // 그리고 이 앱의 캡션은 장식이 아니라 버튼 순서·상태 설명을 담는다.
    test('흰 카드 위', () {
      expect(
        contrast(AppColors.surfaceLowLight, AppColors.onSurfaceMutedLight),
        greaterThanOrEqualTo(_aaa),
      );
    });

    test('밝은 바탕 위', () {
      expect(
        contrast(AppColors.backgroundLight, AppColors.onSurfaceMutedLight),
        greaterThanOrEqualTo(_aaa),
      );
    });

    test('다크 표면·배경 위', () {
      expect(contrast(AppColors.surfaceLow, AppColors.onSurfaceMuted),
          greaterThanOrEqualTo(_aaa));
      expect(contrast(AppColors.background, AppColors.onSurfaceMuted),
          greaterThanOrEqualTo(_aaa));
    });

    test('다크용 회색을 라이트에 그대로 쓰면 미달이다', () {
      // 이게 실제로 벌어졌던 일. 토큰을 되돌리면 안 되는 이유를 숫자로 남긴다.
      expect(
        contrast(AppColors.backgroundLight, AppColors.onSurfaceMuted),
        lessThan(_aa),
      );
    });
  });

  group('라이트 모드 상태색 — 글자·아이콘으로 쓸 때', () {
    // 상태를 색으로 알리는 자리(연결됨·방해 금지·안전 정지)가 전부 여기 걸린다.
    // 크림 위에서 원본 앰버는 1.82:1, 그린은 2.19:1로 사실상 보이지 않았다.
    test('warningLight는 카드·바탕 모두 통과', () {
      expect(contrast(AppColors.surfaceLowLight, AppColors.warningLight),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.warningLight),
          greaterThanOrEqualTo(_aa));
    });

    test('successLight는 카드·바탕 모두 통과', () {
      expect(contrast(AppColors.surfaceLowLight, AppColors.successLight),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.successLight),
          greaterThanOrEqualTo(_aa));
    });

    test('다크용 앰버·그린을 라이트에 그대로 쓰면 미달이다', () {
      expect(contrast(AppColors.backgroundLight, AppColors.warning),
          lessThan(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.success),
          lessThan(_aa));
    });
  });

  group('라이트 모드에서 danger를 글자로 쓸 때', () {
    test('dangerLight는 카드·바탕 모두 통과', () {
      expect(contrast(AppColors.surfaceLowLight, AppColors.dangerLight),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.dangerLight),
          greaterThanOrEqualTo(_aa));
    });

    test('다크용 danger를 그대로 쓰면 미달이다', () {
      expect(contrast(AppColors.backgroundLight, AppColors.danger), lessThan(_aa));
    });
  });

  // ── 실제 위젯 조합 ──────────────────────────────────────────────────────
  //
  // 위 그룹들은 **토큰 쌍**을 검사한다. 그런데 실제 미달은 화면에서 토큰을
  // 조합하는 자리에서 났다 -- 팔레트는 통과하는데 위젯은 떨어지는 것이다.
  // 여기서는 화면이 쓰는 조합 그대로를 숫자로 박는다.

  /// 알파 합성 -- CircleAvatar 같은 '틴트 배경'을 실제 보이는 색으로 만든다.
  Color over(Color fg, Color bg, double alpha) => Color.fromARGB(
        255,
        (fg.r * 255 * alpha + bg.r * 255 * (1 - alpha)).round(),
        (fg.g * 255 * alpha + bg.g * 255 * (1 - alpha)).round(),
        (fg.b * 255 * alpha + bg.b * 255 * (1 - alpha)).round(),
      );

  group('강조색을 면으로 쓰는 자리 (appOnAccent)', () {
    // 다크의 강조색은 밝고 라이트 전용 변형은 어둡다 -- 한쪽에 맞춘 글자색을
    // 두 모드에 그대로 쓰면 반대쪽이 무너진다. 실제로 그랬던 자리들이다.
    const darkOnAccent = Colors.black;
    const lightOnAccent = Colors.white;

    test('제안 순서 배지 — 두 모드 모두 통과', () {
      expect(contrast(AppColors.primary, darkOnAccent),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.primaryLight, lightOnAccent),
          greaterThanOrEqualTo(_aa));
    });

    test('알림 개수 배지 — 두 모드 모두 통과', () {
      expect(contrast(AppColors.danger, darkOnAccent),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.dangerLight, lightOnAccent),
          greaterThanOrEqualTo(_aa));
    });

    test('검정 고정이면 라이트에서 미달이다 (회귀 방지의 근거)', () {
      // 이 두 값이 리뷰가 잡은 3.78:1 / 3.72:1이다.
      expect(contrast(AppColors.primaryLight, darkOnAccent), lessThan(_aa));
      expect(contrast(AppColors.dangerLight, darkOnAccent), lessThan(_aa));
    });

    test('흰색 고정이면 다크에서 미달이다', () {
      expect(contrast(AppColors.primary, lightOnAccent), lessThan(_aa));
      expect(contrast(AppColors.danger, lightOnAccent), lessThan(_aa));
    });
  });

  group('강조색 틴트 위에 같은 강조색 글자', () {
    // 제안 화면 단계 타임라인의 순서 원이 이 모양이었다(18% 틴트 + 강조색 숫자).
    //
    // **골드 시절에는 이 조합이 아예 불가능했다**: 틴트 10/18/30%가 각각
    // 4.85 / 4.32 / 3.61:1이었고 틴트를 걷어낸 상한도 5.56:1이라, 어느
    // 알파를 골라도 '겨우 넘거나 미달'이었다. 그래서 면을 채우고 반대색을
    // 얹는 쪽(appOnAccent)을 택했다.
    //
    // 인디고로 바꾸면서 그 제약이 사라졌다. 아래는 **지금 값의 여유**를
    // 기록해 두는 것이고, 화면이 쓰는 방식(면을 채운다)은 그대로다 --
    // 여유가 생겼다고 더 약한 쪽으로 되돌릴 이유는 없다.
    test('틴트 위 강조색 글자도 이제는 AA를 넘는다', () {
      for (final alpha in [0.10, 0.18, 0.30]) {
        expect(
          contrast(
            over(AppColors.primaryLight, AppColors.surfaceLowLight, alpha),
            AppColors.primaryLight,
          ),
          greaterThanOrEqualTo(_aa),
          reason: '알파 $alpha',
        );
      }
    });

    test('틴트가 짙어질수록 나빠지는 방향은 그대로다', () {
      // 배경이 글자색 쪽으로 다가가므로 알파가 커지면 대비는 단조 감소한다.
      // 이 성질이 깨지면 over() 계산이 잘못된 것이다.
      final light = contrast(
        over(AppColors.primaryLight, AppColors.surfaceLowLight, 0.10),
        AppColors.primaryLight,
      );
      final heavy = contrast(
        over(AppColors.primaryLight, AppColors.surfaceLowLight, 0.30),
        AppColors.primaryLight,
      );
      expect(heavy, lessThan(light));
      // 30%까지 짙게 해도 AA는 지킨다 -- 골드는 여기서 3.61:1이었다.
      expect(heavy, greaterThanOrEqualTo(_aa));
    });

    test('강조색 자체는 흰 면 위에서 AAA를 넘는다', () {
      // 고령 사용자 기준 7:1을 넘는 가장 선명한 인디고로 고른 값이다.
      expect(contrast(AppColors.surfaceLowLight, AppColors.primaryLight),
          greaterThanOrEqualTo(_aaa));
    });

    test('면을 채우고 appOnAccent를 얹으면 통과한다', () {
      expect(contrast(AppColors.primaryLight, Colors.white),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.primary, Colors.black),
          greaterThanOrEqualTo(_aa));
    });
  });

  group('빈 상태 안내문', () {
    // 설정의 '다시 추천 안 하는 항목이 없어요.'가 Colors.grey였다.
    test('Colors.grey는 밝은 바탕에서 미달이다', () {
      expect(contrast(AppColors.backgroundLight, Colors.grey), lessThan(_aa));
    });

    test('보조 텍스트 토큰이면 두 모드 모두 AAA', () {
      expect(contrast(AppColors.backgroundLight, AppColors.onSurfaceMutedLight),
          greaterThanOrEqualTo(_aaa));
      expect(contrast(AppColors.background, AppColors.onSurfaceMuted),
          greaterThanOrEqualTo(_aaa));
    });
  });

  group('다크 모드', () {
    test('강조색은 다크 배경 위 글자로도 통과', () {
      expect(contrast(AppColors.background, AppColors.primary),
          greaterThanOrEqualTo(_aa));
    });

    test('다크용 회색 캡션은 다크 표면 위에서 통과', () {
      expect(contrast(AppColors.surfaceLow, AppColors.onSurfaceMuted),
          greaterThanOrEqualTo(_aa));
    });
  });
}
