import 'package:flutter/material.dart';

class ApplianceButton {
  const ApplianceButton({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
  });

  final String id;
  final String label;
  final int x;
  final int y;

  factory ApplianceButton.fromJson(Map<String, dynamic> json) => ApplianceButton(
        id: json['id'] as String,
        label: json['label'] as String,
        x: json['x'] as int,
        y: json['y'] as int,
      );

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'x': x, 'y': y};
}

/// 가전의 **종류**. 개별 기기의 식별자(`id`)와 다른 개념이다.
///
/// 같은 종류를 여러 대 등록할 수 있다 -- 거실 에어컨과 안방 에어컨은
/// `category`가 같고 `id`가 다르다.
///
/// 값은 **안정적인 문자열**이고 서버·키오스크와 같은 것을 쓴다. 아이콘은
/// 여기서 파생될 뿐, 반대로 아이콘에서 종류를 정하지 않는다.
///
/// 이름으로 종류를 추측하지도 않는다 -- "에어컨 옆 선풍기" 같은 이름이
/// 틀리게 되고, 한 번 틀리면 사용자가 고칠 방법이 없다.
enum ApplianceCategory {
  microwave('microwave', '전자레인지', Icons.microwave),
  airConditioner('air_conditioner', '에어컨', Icons.ac_unit),
  washingMachine('washing_machine', '세탁기', Icons.local_laundry_service),
  induction('induction', '인덕션', Icons.soup_kitchen),
  riceCooker('rice_cooker', '밥솥', Icons.rice_bowl),
  other('other', '기타', Icons.widgets_outlined);

  const ApplianceCategory(this.value, this.label, this.icon);

  /// 저장·전송에 쓰는 안정적인 값.
  final String value;

  /// 화면에 보일 종류 이름.
  final String label;

  /// 이 종류의 그림. **저장하지 않는다** -- 아이콘 코드포인트를 직렬화하면
  /// 릴리즈 빌드의 아이콘 트리셰이킹이 깨진다.
  final IconData icon;

  /// 모르는 값은 **거절하지 않는다.**
  ///
  /// 서버가 새 종류를 알고 있을 수 있고, 거절하거나 던지면 목록 전체를
  /// 읽지 못하게 된다. 모르면 `other`로 받고 이름·버튼은 그대로 살린다.
  static ApplianceCategory parse(String? raw) {
    if (raw == null || raw.isEmpty) return ApplianceCategory.other;
    for (final c in ApplianceCategory.values) {
      if (c.value == raw) return c;
    }
    return ApplianceCategory.other;
  }

  /// 예전 `icon` 힌트에서 종류를 되살리는 **명시적** 표.
  ///
  /// 알려진 값만 옮긴다. 커스텀 가전이 보내던 `"custom"`이 여기 없는 것도
  /// 의도한 것이다 -- 그 값은 종류를 담은 적이 없다.
  static ApplianceCategory fromLegacyIcon(String? icon) => switch (icon) {
        'microwave' => ApplianceCategory.microwave,
        'induction' => ApplianceCategory.induction,
        'aircon' || 'air_conditioner' => ApplianceCategory.airConditioner,
        _ => ApplianceCategory.other,
      };
}

// 내장 가전(전자레인지/인덕션)은 백엔드 규칙 기반 의도 해석기에 목적→버튼 매핑이
// 있어서 음성 명령이 되지만, 사용자가 새로 등록한 가전(isCustom)은 그 매핑이
// 없으므로 버튼을 직접 탭해서 실행하는 수동 모드로만 동작한다.
class ApplianceMap {
  const ApplianceMap({
    required this.id,
    required this.name,
    required this.category,
    required this.rows,
    required this.cols,
    required this.buttons,
    this.location,
    this.isCustom = false,
    this.isDemo = false,
    this.photoPath,
    this.canExecute = true,
    this.readiness = 'unknown',
    this.readinessReasons = const [],
    this.readinessKnown = false,
    this.revision = 0,
  });

  final String id;
  final String name;

  /// 어디에 있는 가전인가(거실·안방...). 없을 수 있다.
  ///
  /// 같은 종류를 여러 대 등록할 수 있는 제품이라, 이름만으로는 '에어컨'과
  /// '에어컨'을 구분할 수 없다. **이 폰에만 남는다** -- 서버 payload는
  /// 따로 조립하고 이 값을 싣지 않는다. 집 안 어디에 뭐가 있는지는 굳이
  /// 밖으로 내보낼 이유가 없다.
  final String? location;

  /// 이 기기의 **종류**. 도메인의 단일 진실원천이다.
  final ApplianceCategory category;

  /// 그림은 종류에서 나온다 -- 따로 들고 있지 않는다.
  IconData get icon => category.icon;

  final int rows;
  final int cols;
  final List<ApplianceButton> buttons;
  final bool isCustom;

  /// 데모 세션이 세운 **표본**인가.
  ///
  /// 저장하지 않는다 -- 표본은 기기에 남지 않는다. 화면은 이 값을 보고
  /// '데모'라고 적어야 한다. 표본을 진짜 등록된 가전처럼 보여주면, 심사
  /// 자리에서 우리가 무엇을 실제로 만들었는지 아무도 구분할 수 없다.
  final bool isDemo;

  /// 이 가전을 지금 맡길 수 있나 (서버 F1 판정).
  ///
  /// **등록됐다는 것과 조작할 수 있다는 것은 다르다.** 주소는 맞는데
  /// 선이 안 꽂혀 있거나, 전송은 되는데 모터가 홈을 안 잡았거나,
  /// 좌표를 아직 안 맞춘 상태가 있다.
  ///
  /// 서버 정보가 없을 때(오프라인 폴백·기기 저장분)는 막지 않는다 --
  /// 모르는 것을 '안 됨'으로 단정하면 하드웨어 없이 도는 경로가 죽는다.
  /// 서버는 준비 안 된 실행을 어차피 412로 거절한다(이중 방어).
  final bool canExecute;

  /// disconnected | needs_setup | operable | unknown
  ///
  /// `unknown`은 **서버에게 물어본 적이 없다**는 뜻이다. 'operable'과
  /// 구분해야 한다 -- 서버를 거치지 않는 경로(BLE)에서 "확인된 조작 가능"과
  /// "그냥 모름"을 같은 값으로 보면 안 된다.
  final String readiness;

  /// 서버가 이 가전의 준비 상태를 실제로 말해줬는가.
  /// 기기 저장분·하드코딩 폴백·구버전 서버 응답에서는 false다.
  final bool readinessKnown;

  /// 마지막으로 본 서버 판 번호. 저장할 때 "내가 본 판은 이거였다"고
  /// 함께 보내면, 그 사이 다른 기기가 먼저 바꿨는지 서버가 가려준다.
  /// 0이면 모른다(최초 등록·기기 저장분) -- 그때는 밝히지 않고 보낸다.
  final int revision;

  /// **서버를 거치지 않는 경로**(BLE 릴레이)로 내보내도 되는가.
  ///
  /// HTTP 실행은 서버가 412로 막아 주지만 BLE는 ESP32로 바로 나간다 --
  /// 게이트가 아예 없다. 그래서 여기서는 fail-open을 좁힌다: 서버가 한 번
  /// "안 된다"고 말한 가전은 BLE로도 내보내지 않는다. 서버 얘기를 들은
  /// 적이 없으면(하드코딩 폴백) 막지 않는다 -- 막으면 서버가 죽었을 때
  /// 조작 수단이 통째로 사라진다.
  bool get mayDispatchWithoutServer => !readinessKnown || canExecute;

  /// 맡길 수 없는 이유. '안 됩니다'만 말하면 할 수 있는 일이 없다.
  final List<String> readinessReasons;


  /// 등록 시 찍은 버튼 패널 사진의 영구 경로 (앱 문서 폴더 아래).
  /// image_picker의 임시 캐시 파일을 그대로 저장하면 OS가 지워버리므로,
  /// 저장 시점에 문서 폴더로 복사한 경로만 여기 들어온다. 내장 가전은 null.
  final String? photoPath;

  /// 목록에서 이 가전을 가리키는 한 줄. 위치가 있으면 같이 적는다 --
  /// '에어컨'이 두 대일 때 이름만으로는 어느 쪽인지 알 수 없다.
  String get displayName {
    final where = location;
    if (where == null || where.isEmpty) return name;
    return '$where $name';
  }

  ApplianceButton? buttonAt(int x, int y) {
    try {
      return buttons.firstWhere((b) => b.x == x && b.y == y);
    } catch (_) {
      return null;
    }
  }

  String labelFor(String buttonId) {
    try {
      return buttons.firstWhere((b) => b.id == buttonId).label;
    } catch (_) {
      return buttonId;
    }
  }

  // 아이콘은 코드포인트로 직렬화하면 릴리즈 빌드의 아이콘 트리셰이킹이 깨질 수
  // 있어서, 커스텀 가전은 항상 고정 아이콘을 쓰고 저장/복원 대상에서 제외한다.
  factory ApplianceMap.fromJson(Map<String, dynamic> json) => ApplianceMap(
        id: json['id'] as String,
        name: json['name'] as String,
        location: json['location'] as String?,
        // 종류가 진실원천이다. 없으면(예전 저장분) icon 힌트에서 **명시적인
        // 표로만** 되살리고, 그래도 모르면 other -- 이름으로 추측하지 않는다.
        category: json.containsKey('category')
            ? ApplianceCategory.parse(json['category'] as String?)
            : ApplianceCategory.fromLegacyIcon(json['icon'] as String?),
        rows: json['rows'] as int,
        cols: json['cols'] as int,
        buttons: (json['buttons'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(ApplianceButton.fromJson)
            .toList(),
        isCustom: true,
        photoPath: json['photo_path'] as String?,
        // 서버 응답에만 있는 값 — 기기에 저장된 정의에는 없다(저장하지
        // 않는다: 살아 있는 준비 상태는 재확인 전까지 사실이 아니다).
        // 서버 응답에만 있는 값 — 기기 저장분에는 없다. 없으면 막지
        // 않지만(모르는 것을 '안 됨'으로 단정하면 서버가 죽었을 때 조작
        // 수단이 사라진다) '확인됨'이라고 말하지도 않는다.
        canExecute: json['can_execute'] as bool? ?? true,
        readiness: json['readiness'] as String? ?? 'unknown',
        readinessReasons:
            (json['readiness_reasons'] as List<dynamic>?)?.cast<String>() ??
                const [],
        readinessKnown: json.containsKey('can_execute'),
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );

  /// 서버에서 받은 정의에 **이 폰의 사진 경로**를 얹는다.
  ///
  /// 사진은 기기 로컬 파일이라 서버가 모른다. 서버 내용으로 통째로 갈아
  /// 끼우면 등록할 때 찍어둔 버튼 패널 사진이 조용히 사라진다.
  ApplianceMap withPhotoFrom(ApplianceMap other) => ApplianceMap(
        id: id,
        name: name,
        location: location,
        category: category,
        rows: rows,
        cols: cols,
        buttons: buttons,
        isCustom: isCustom,
        isDemo: isDemo,
        photoPath: other.photoPath,
        canExecute: canExecute,
        readiness: readiness,
        readinessReasons: readinessReasons,
        readinessKnown: readinessKnown,
        revision: revision,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (location != null && location!.isNotEmpty) 'location': location,
        // 종류만 저장한다. 아이콘 코드포인트를 직렬화하면 릴리즈 빌드의
        // 아이콘 트리셰이킹이 깨진다.
        'category': category.value,
        'rows': rows,
        'cols': cols,
        'buttons': buttons.map((b) => b.toJson()).toList(),
        // 판 번호는 기기에도 남긴다 — 오프라인에서 편집한 뒤 다시
        // 연결됐을 때 "내가 본 판"을 말할 수 있어야 한다.
        if (revision > 0) 'revision': revision,
        if (photoPath != null) 'photo_path': photoPath,
      };
}

/// 데모 세션에서만 세우는 **표본 가전**.
///
/// 이름에 '데모'가 들어 있고 `isDemo`도 참이다. 둘 중 하나만으로는
/// 부족하다 -- 이름만 보고 지나칠 수도, 뱃지를 못 그리는 자리도 있다.
final kDemoAppliances = <ApplianceMap>[
  _demo(kApplianceTemplates.first),
  _demo(kApplianceTemplates.firstWhere((t) => t.id == 'aircon')),
];

ApplianceMap _demo(ApplianceMap template) => ApplianceMap(
      id: 'demo_${template.id}',
      name: '데모 ${template.name}',
      category: template.category,
      rows: template.rows,
      cols: template.cols,
      buttons: template.buttons,
      isDemo: true,
    );

/// **고를 수 있는 종류의 예시**지 사용자가 소유한 가전이 아니다.
///
/// 이 목록이 곧 설치 목록 행세를 하던 것이 "전자레인지 데모 앱"으로
/// 보이던 원인이었다. 설치된 가전은 `installedAppliancesProvider`가
/// 들고 있고, 여기 있는 것은 기본 버튼 배치를 제공하는 본보기다.
const kApplianceTemplates = <ApplianceMap>[
  ApplianceMap(
    id: 'microwave',
    name: '전자레인지',
    category: ApplianceCategory.microwave,
    rows: 4,
    cols: 3,
    buttons: [
      ApplianceButton(id: 'BT-01', label: '10초',    x: 0, y: 0),
      ApplianceButton(id: 'BT-02', label: '30초',    x: 1, y: 0),
      ApplianceButton(id: 'BT-03', label: '1분',     x: 2, y: 0),
      ApplianceButton(id: 'BT-04', label: '5분',     x: 0, y: 1),
      ApplianceButton(id: 'BT-07', label: '해동',    x: 0, y: 2),
      ApplianceButton(id: 'BT-08', label: '즉석밥',    x: 1, y: 2),
      ApplianceButton(id: 'BT-09', label: '냉동식품', x: 2, y: 2),
      ApplianceButton(id: 'BT-10', label: '라면', x: 1, y: 1),
      ApplianceButton(id: 'BT-06', label: '취소',    x: 1, y: 3),
      ApplianceButton(id: 'BT-05', label: '시작',    x: 2, y: 3),
    ],
  ),
  ApplianceMap(
    id: 'induction',
    name: '인덕션',
    category: ApplianceCategory.induction,
    rows: 3,
    cols: 4,
    buttons: [
      ApplianceButton(id: 'IN-01', label: '전원',  x: 0, y: 0),
      ApplianceButton(id: 'IN-02', label: '화력+', x: 1, y: 0),
      ApplianceButton(id: 'IN-03', label: '화력-', x: 2, y: 0),
      ApplianceButton(id: 'IN-04', label: '타이머', x: 3, y: 0),
      ApplianceButton(id: 'IN-05', label: '1단',   x: 0, y: 1),
      ApplianceButton(id: 'IN-06', label: '3단',   x: 1, y: 1),
      ApplianceButton(id: 'IN-07', label: '5단',   x: 2, y: 1),
      ApplianceButton(id: 'IN-08', label: '보온',  x: 3, y: 1),
      ApplianceButton(id: 'IN-09', label: '시작',  x: 2, y: 2),
      ApplianceButton(id: 'IN-10', label: '취소',  x: 3, y: 2),
    ],
  ),
  ApplianceMap(
    id: 'aircon',
    name: '에어컨',
    category: ApplianceCategory.airConditioner,
    rows: 3,
    cols: 3,
    buttons: [
      ApplianceButton(id: 'AC-01', label: '전원',    x: 0, y: 0),
      ApplianceButton(id: 'AC-02', label: '온도-',   x: 1, y: 0),
      ApplianceButton(id: 'AC-03', label: '온도+',   x: 2, y: 0),
      ApplianceButton(id: 'AC-04', label: '냉방',    x: 0, y: 1),
      ApplianceButton(id: 'AC-05', label: '제습',    x: 1, y: 1),
      ApplianceButton(id: 'AC-06', label: '송풍',    x: 2, y: 1),
      ApplianceButton(id: 'AC-07', label: '바람세기', x: 0, y: 2),
      ApplianceButton(id: 'AC-08', label: '예약',    x: 1, y: 2),
      ApplianceButton(id: 'AC-09', label: '취소',    x: 2, y: 2),
    ],
  ),
];
