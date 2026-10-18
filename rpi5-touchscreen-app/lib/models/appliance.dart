import 'package:flutter/material.dart';

class ApplianceButton {
  const ApplianceButton({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    this.behavior = 'unknown',
  });

  final String id;
  final String label;
  final int x;
  final int y;

  /// 서버 버튼 데이터의 누름 성질(`/appliances` buttons[].behavior) — toggle(한 번 더 누르면 되돌아감: 켜고 끄는 한 버튼) |
  /// idempotent | unknown. 옛 서버·하드코딩 폴백이면 unknown — 모르는 것을 토글이라 단정하지 않는다.
  final String behavior;

  /// 켜고 끄는 한 버튼인가 — 다시 누르면 꺼질 수 있다(접근성 감사 10/18 — '한 번 더 하기' 확인 창 경고).
  bool get isToggle => behavior == 'toggle';
}

class ApplianceMap {
  const ApplianceMap({
    required this.id,
    required this.name,
    required this.category,
    required this.rows,
    required this.cols,
    required this.buttons,
    this.canExecute = true,
    this.readiness = 'unknown',
    this.readinessReasons = const [],
    this.controlPath = 'physical',
    this.isCustom = false,
    this.hasPanelMapping = false,
  });

  final String id;

  /// 사용자가 휴대폰 앱에서 등록한 가전인가(서버 `/appliances`의 `is_custom`). 서버가 말하지 않으면 false —
  /// 그때는 '설정이 필요해요'라고 단정하지 않는다(평가 6차 10/18).
  final bool isCustom;

  /// 서버가 사진 위 버튼 자리 기록(`panel_mapping`)을 보냈나 — 폰의 `PanelMapping.fromJson`과 같은 기준
  /// (사진 크기가 있는 기록만).
  final bool hasPanelMapping;

  /// 위치(사진 위 버튼 자리)를 아직 맞추지 않은 가전 — 폰 `needsPanelMapping`과 같은 판정(데모 표본은 서버에 없다).
  /// 폰은 이런 가전을 '설정이 필요해요'라고 한다. 키오스크도 같은 말을 쓴다(평가 6차 10/18 — 키오스크는 '눌러 드려요'였다).
  bool get needsPanelMapping => isCustom && !isThinq && !hasPanelMapping;
  final String name;

  /// 이 가전을 무엇으로 조작하는가 -- `physical`(갠트리가 버튼을 누름) 또는
  /// `thinq`(클라우드 가전). 서버 `/appliances`의 `control_path`이고, 없으면
  /// 종전대로 물리 경로다. ThinQ 가전에는 누를 버튼이 없다 -- 조작판을
  /// 그리지 않는다(폰과 같은 규칙).
  final String controlPath;

  /// ThinQ(클라우드) 경로 가전인가.
  bool get isThinq => controlPath == 'thinq';

  /// 서버가 이름에 '(연습)'을 붙인 연습 가전인가(예: 실제 모드 안의 'LG 세탁기(연습)' — 2026-10-18 연습 세탁기).
  /// 서버 구성 가전의 이름 표기가 근거다. 모의 모드 이름의 '(모의)'는 종전 그대로 둔다(타일 배지 'LG 가전').
  bool get isPractice => name.contains('(연습)');

  /// 화면에 쓰는 이름(접근성 감사 10/18) — 연습 가전은 '연습 세탁기'([practiceDisplayName], 폰과 같은 규칙). 서버 이름
  /// 데이터('LG 세탁기(연습)')는 그대로 두고 화면 표시만 바꾼다. 예전 'LG 세탁기'는 실제 '세탁기'와 헷갈렸다.
  String get displayName => practiceDisplayName(name);

  /// 타일·버튼판 제목에 쓰는 이름 — [displayName]과 같다.
  String get tileName => displayName;

  /// 이 기기의 **종류**. 서버가 준 값을 그대로 보관한다.
  ///
  /// 아이콘만 뽑고 버리면 파서 밖에서 종류를 다시 볼 수 없어서, 폰에서
  /// 등록한 종류가 키오스크까지 이어졌는지 확인할 방법이 사라진다.
  final String category;

  /// 그림은 종류에서 나온다 -- 따로 들고 있지 않는다. 단 하나의 예외는 서버가 세운 **모의 선풍기**(id `fan`,
  /// 종류 목록에 선풍기가 없어 `other`)다 — 서버의 고정 id로만 고르고 이름으로 추측하지 않는다(평가 6차 10/18).
  IconData get icon => id == kServerFanId && category == 'other'
      ? applianceIconFor('fan')
      : applianceIconFor(category);

  final int rows;
  final int cols;
  final List<ApplianceButton> buttons;

  /// 이 가전을 지금 맡길 수 있나 (서버 F1 판정).
  ///
  /// **등록됐다는 것과 조작할 수 있다는 것은 다르다.** 서버 정보가 없는
  /// 하드코딩 폴백에서는 막지 않는다 — 모르는 것을 '안 됨'으로 단정하면
  /// 서버가 죽었을 때 조작 수단이 통째로 사라진다. 준비 안 된 실행은
  /// 서버가 412로 거절한다(이중 방어).
  final bool canExecute;

  /// disconnected | needs_setup | operable | unknown
  ///
  /// `unknown`은 **서버에게 물어본 적이 없다**는 뜻이다(하드코딩 폴백).
  /// 'operable'과 구분한다 -- 확인된 것과 그냥 모르는 것은 다르다.
  final String readiness;

  /// 맡길 수 없는 이유. '안 됩니다'만 말하면 할 수 있는 일이 없다.
  final List<String> readinessReasons;

  ApplianceButton? buttonAt(int x, int y) {
    try {
      return buttons.firstWhere((b) => b.x == x && b.y == y);
    } catch (_) {
      return null;
    }
  }
}

/// 연습 가전 화면 이름 규칙(접근성 감사 10/18, 폰 `practiceDisplayName`과 같은 규칙) — 이름에 '(연습)'이 붙은 서버 연습
/// 기기면 '(연습)'과 앞의 'LG '를 떼고 '연습 '을 앞에: 'LG 세탁기(연습)' → '연습 세탁기'. 그 밖의 이름은 그대로.
String practiceDisplayName(String name) {
  if (!name.contains('(연습)')) return name;
  var base = name.replaceAll('(연습)', '').trim();
  if (base.startsWith('LG ')) base = base.substring(3).trim();
  return base.isEmpty ? '연습 가전' : '연습 $base';
}

// 폰 앱(app/lib/models/appliance.dart)과 동일한 버튼 배치를 유지한다.
// (리스트 인덱싱은 const 표현식이 아니라 기본 파라미터 값으로 못 쓰므로,
// 기본값으로 참조할 항목은 이렇게 별도 top-level const로 분리해 둔다.)
const kMicrowaveAppliance = ApplianceMap(
  id: 'microwave',
  name: '전자레인지',
  category: 'microwave',
  rows: 4,
  cols: 3,
  buttons: [
    ApplianceButton(id: 'BT-01', label: '10초', x: 0, y: 0),
    ApplianceButton(id: 'BT-02', label: '30초', x: 1, y: 0),
    ApplianceButton(id: 'BT-03', label: '1분', x: 2, y: 0),
    ApplianceButton(id: 'BT-04', label: '5분', x: 0, y: 1),
    ApplianceButton(id: 'BT-07', label: '해동', x: 0, y: 2),
    ApplianceButton(id: 'BT-08', label: '즉석밥', x: 1, y: 2),
    ApplianceButton(id: 'BT-09', label: '냉동식품', x: 2, y: 2),
    ApplianceButton(id: 'BT-10', label: '라면', x: 1, y: 1),
    ApplianceButton(id: 'BT-06', label: '취소', x: 1, y: 3),
    ApplianceButton(id: 'BT-05', label: '시작', x: 2, y: 3),
  ],
);

const kInductionAppliance = ApplianceMap(
  id: 'induction',
  name: '인덕션',
  category: 'induction',
  rows: 3,
  cols: 4,
  buttons: [
    ApplianceButton(id: 'IN-01', label: '전원', x: 0, y: 0),
    ApplianceButton(id: 'IN-02', label: '화력+', x: 1, y: 0),
    ApplianceButton(id: 'IN-03', label: '화력-', x: 2, y: 0),
    ApplianceButton(id: 'IN-04', label: '타이머', x: 3, y: 0),
    ApplianceButton(id: 'IN-05', label: '1단', x: 0, y: 1),
    ApplianceButton(id: 'IN-06', label: '3단', x: 1, y: 1),
    ApplianceButton(id: 'IN-07', label: '5단', x: 2, y: 1),
    ApplianceButton(id: 'IN-08', label: '보온', x: 3, y: 1),
    ApplianceButton(id: 'IN-09', label: '시작', x: 2, y: 2),
    ApplianceButton(id: 'IN-10', label: '취소', x: 3, y: 2),
  ],
);

const kAppliances = <ApplianceMap>[kMicrowaveAppliance, kInductionAppliance];

/// 서버가 준 **종류(category)** → 아이콘.
///
/// 종류가 진실원천이고 그림은 여기서 파생한다. 서버는 그림을 모른다.
/// 모르는 종류는 거절하지 않고 일반 아이콘으로 떨어진다 -- 앞선 버전의
/// 폰이 새 종류를 등록했을 수 있고, 그때 목록 전체를 못 읽으면 안 된다.
///
/// 폰(`app/lib/models/appliance.dart`)과 **같은 표**를 쓴다. 두 화면이 같은
/// 가전을 다른 그림으로 그리면 같은 제품으로 보이지 않는다.
/// 서버 응답에서 종류를 정한다.
///
/// `category`가 있으면 그것이 진실원천이다. 없으면(구버전 서버) 예전
/// `icon` 힌트에서 **명시적인 표로만** 되살린다 -- 이름이나 다른 값으로
/// 추측하지 않는다. `custom`이 표에 없는 것도 의도한 것이다: 그 값은
/// 종류를 담은 적이 없다.
///
/// 모르는 값은 거절하지 않고 `other`. 앞선 버전의 서버가 새 종류를 알고
/// 있을 수 있고, 그때 목록 전체를 못 읽으면 안 된다.
String categoryFromServer(String? category, String? legacyIcon) {
  if (category != null && category.isNotEmpty) {
    return _known.contains(category) ? category : 'other';
  }
  return switch (legacyIcon) {
    'microwave' => 'microwave',
    'induction' => 'induction',
    'aircon' || 'air_conditioner' => 'air_conditioner',
    _ => 'other',
  };
}

/// 서버가 세우는 모의 선풍기의 가전 id(`rpi/api/thinq_wiring.py`의 `FAN_ID`).
const kServerFanId = 'fan';

const _known = {
  'microwave',
  'air_conditioner',
  'washing_machine',
  'induction',
  'rice_cooker',
  'intercom', // 시연 v3 갭 S6(2026-10-06) — 서버·폰과 같은 값
  // 서버 `ApplianceCategory.AIR_PURIFIER` — 없으면 other로 떨어져 앱 모음 격자가 보였다(실패널 k01, 평가 6차 10/18).
  'air_purifier',
  'other',
};

IconData applianceIconFor(String category) => switch (category) {
      'microwave' => Icons.microwave,
      'induction' => Icons.soup_kitchen,
      'air_conditioner' => Icons.ac_unit,
      'washing_machine' => Icons.local_laundry_service,
      'rice_cooker' => Icons.rice_bowl,
      'intercom' => Icons.doorbell,
      // 폰과 같은 바람 그림(평가 6차 10/18).
      'air_purifier' => Icons.air,
      // 선풍기는 종류 목록에 없다 — 서버 모의 선풍기만 [ApplianceMap.icon]이 이 값으로 부른다. 바람 계열.
      'fan' => Icons.wind_power,
      // 모르는 종류는 전기 플러그 — 앱 모음 격자는 '앱 목록'으로 읽혔다(평가 6차 10/18).
      _ => Icons.power_outlined,
    };

/// GET /appliances 한 항목 → ApplianceMap. 폰에서 등록한 커스텀 가전이
/// 키오스크 조작판이 되는 지점이라, 필드가 이상하면 그 항목만 버린다
/// (호출부에서 try/catch).
ApplianceMap applianceFromServerJson(Map<String, dynamic> json) => ApplianceMap(
      id: json['id'] as String,
      name: json['name'] as String,
      // 종류를 **보관**한다. 없으면(구버전 서버) icon 힌트에서 명시적인
      // 표로만 되살리고, 그래도 모르면 other다.
      category: categoryFromServer(
        json['category'] as String?,
        json['icon'] as String?,
      ),
      rows: json['rows'] as int,
      cols: json['cols'] as int,
      // 준비 상태는 폰과 **같은 값**을 본다 — 한 서버에서 나온다.
      canExecute: json['can_execute'] as bool? ?? true,
      readiness: json['readiness'] as String? ?? 'unknown',
      readinessReasons:
          (json['readiness_reasons'] as List<dynamic>?)?.cast<String>() ??
              const [],
      // G5 — 없으면(옛 서버) 물리 경로.
      controlPath: json['control_path'] as String? ?? 'physical',
      // 평가 6차(10/18) — 폰과 같은 '설정이 필요해요' 판정의 근거. 없으면(옛 서버) 사용자 가전이라 단정하지 않는다.
      isCustom: json['is_custom'] as bool? ?? false,
      hasPanelMapping: _validPanelMapping(json['panel_mapping']),
      buttons: [
        for (final b in json['buttons'] as List<dynamic>)
          ApplianceButton(
            id: (b as Map<String, dynamic>)['id'] as String,
            label: b['label'] as String,
            x: b['x'] as int,
            y: b['y'] as int,
            behavior: b['behavior'] is String ? b['behavior'] as String : 'unknown',
          ),
      ],
    );

/// 폰 `PanelMapping.fromJson`이 기록으로 받아 주는 꼴인가 — 사진 크기(가로·세로 > 0)가 있어야 한다.
bool _validPanelMapping(Object? raw) {
  if (raw is! Map<String, dynamic>) return false;
  final photo = raw['photo'];
  if (photo is! Map<String, dynamic>) return false;
  final w = (photo['width'] as num?)?.toDouble();
  final h = (photo['height'] as num?)?.toDouble();
  return w != null && h != null && w > 0 && h > 0;
}
