/// 팔레트 조합의 명도 대비를 고정한다.
///
/// 왜 테스트로 박아두나: 색은 "예뻐 보이는지"로 판단하게 되고, 대비 미달은 눈으로
/// 잘 안 잡힌다. 실제로 이 앱에서 가장 중요한 버튼 둘(제안 승인·긴급 정지)이 각각
/// 2.25:1, 3.63:1이었다 — 채도 있는 색 위에 흰 글자를 얹었기 때문이다. 검정이면
/// 9.34:1, 5.78:1이다.
///
/// 캡션 쪽은 더 얄궂었다. AppText.caption이 **다크용 회색을 상수로** 물고 있어서
/// 라이트 모드의 크림 배경 위에서 2.48:1이었다. app_colors.dart에 "하드코딩하면
/// 크림 배경에서 안 보인다"는 주석이 이미 있었는데 타이포 토큰 자신이 그걸 어겼다.
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
      '골드(주요 실행)': AppColors.primary,
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
    test('크림 표면 위', () {
      expect(
        contrast(AppColors.surfaceLowLight, AppColors.onSurfaceMutedLight),
        greaterThanOrEqualTo(_aaa),
      );
    });

    test('크림 배경 위', () {
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
    test('warningLight는 크림 표면·배경 모두 통과', () {
      expect(contrast(AppColors.surfaceLowLight, AppColors.warningLight),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.warningLight),
          greaterThanOrEqualTo(_aa));
    });

    test('successLight는 크림 표면·배경 모두 통과', () {
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
    test('dangerLight는 크림 표면·배경 모두 통과', () {
      expect(contrast(AppColors.surfaceLowLight, AppColors.dangerLight),
          greaterThanOrEqualTo(_aa));
      expect(contrast(AppColors.backgroundLight, AppColors.dangerLight),
          greaterThanOrEqualTo(_aa));
    });

    test('다크용 danger를 그대로 쓰면 미달이다', () {
      expect(contrast(AppColors.backgroundLight, AppColors.danger), lessThan(_aa));
    });
  });

  group('다크 모드', () {
    test('골드는 다크 배경 위 글자로도 통과', () {
      expect(contrast(AppColors.background, AppColors.primary),
          greaterThanOrEqualTo(_aa));
    });

    test('다크용 회색 캡션은 다크 표면 위에서 통과', () {
      expect(contrast(AppColors.surfaceLow, AppColors.onSurfaceMuted),
          greaterThanOrEqualTo(_aa));
    });
  });
}
