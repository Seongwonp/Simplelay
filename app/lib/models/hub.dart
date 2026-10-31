/// 허브(RPi5 서버)에 관한 작은 응답 모양들 — `/status`의 개발자 모드·정지 대기,
/// `/hub/location`, `/mapping/frame`, 사진 매핑 저장, 확인 주행.
library;

/// `/status` 중 탭 구조·대기 표시가 쓰는 값만.
class HubStatus {
  const HubStatus({
    this.developerMode = false,
    this.running = false,
    this.jobId,
    this.lastJobId,
    this.holdState,
    this.holdStopOutcome,
    this.holdDetail,
    this.estopLatched = false,
    this.estopDetail,
    this.estopReported,
    this.actuatorLinkUp,
  });

  /// 서버 `SIMPLELAY_DEV_MODE`. 참일 때만 폰에 '개발자' 탭이 생긴다.
  final bool developerMode;

  /// 서버가 지금 실행 중인가(`/status.running`). 키오스크·루틴이 시작한 실행도
  /// 여기로 안다 — 폰이 추적하지 않는 실행의 음성 정지 듣기에 쓴다(10/8 인계 5차 §2).
  final bool running;

  /// 실행 중인 job(`/status.job_id`) — 실행이 끝나면 null. 음성 정지가 "이 실행에
  /// 이미 보냈다"를 실행 단위로 묶는 데 쓴다(10/8 리뷰). 옛 서버는 없다(null).
  final String? jobId;

  /// 마지막으로 끝난 job(`/status.last_job_id`). 정지 버튼 위 대기는 실행이 끝난
  /// 뒤라 job_id가 없다 — 대기의 식별에 이것을 쓴다.
  final String? lastJobId;

  /// hovering_stop | stopping | parking | parked | fault | released | null
  final String? holdState;

  /// stopped | requested_unconfirmed | drive_fault | null
  final String? holdStopOutcome;
  final String? holdDetail;

  /// 콘센트 모듈 비상정지 걸림(2026-10-05). 옛 서버·보고 수단 없는 실행기(null)는
  /// 걸리지 않은 것으로 본다 — 실행 거절은 어차피 서버가 한다.
  final bool estopLatched;

  /// 걸린 사유(서버 문장). 걸리지 않았으면 null.
  final String? estopDetail;

  /// `/status.estop_latched` 원래 값 — 보고 수단이 없거나 아직 모르면 null.
  /// [estopLatched]와 달리 null을 false로 접지 않는다(준비 판정 변화 감지용, 검토 M1).
  final bool? estopReported;

  /// `/status.actuator_link_up` — 로컬 누름 장치(RPi4) 링크. 보고하지 않는 대상이면 null.
  final bool? actuatorLinkUp;

  /// 서버가 **로컬 실행 대상**의 준비 판정에 쓰는 신호(걸림·링크). 이것이 바뀌면 가전 목록의
  /// 준비 판정도 바뀌었을 수 있다(`rpi/api/readiness_view.py`의 로컬 분기, 검토 M1).
  ({bool? estop, bool? linkUp}) get localGate =>
      (estop: estopReported, linkUp: actuatorLinkUp);

  factory HubStatus.fromJson(Map<String, dynamic> json) => HubStatus(
        // 옛 서버는 이 키가 없다 -- 없으면 꺼진 것으로 본다.
        developerMode: json['developer_mode'] == true,
        running: json['running'] == true,
        jobId: json['job_id'] is String ? json['job_id'] as String : null,
        lastJobId:
            json['last_job_id'] is String ? json['last_job_id'] as String : null,
        holdState: json['hold_state'] as String?,
        holdStopOutcome: json['hold_stop_outcome'] as String?,
        holdDetail: json['hold_detail'] as String?,
        estopLatched: json['estop_latched'] == true,
        estopDetail: json['estop_latched'] == true && json['estop_detail'] is String
            ? json['estop_detail'] as String
            : null,
        estopReported:
            json['estop_latched'] is bool ? json['estop_latched'] as bool : null,
        actuatorLinkUp: json['actuator_link_up'] is bool
            ? json['actuator_link_up'] as bool
            : null,
      );
}

/// `/hub/location` 응답.
class HubLocation {
  const HubLocation({required this.source, this.lat, this.lon, this.nx, this.ny});

  /// app(폰에서 저장) | env(서버 환경 변수) | none
  final String source;
  final double? lat;
  final double? lon;
  final int? nx;
  final int? ny;

  bool get isSet => source != 'none';

  factory HubLocation.fromJson(Map<String, dynamic> json) => HubLocation(
        source: json['source'] as String? ?? 'none',
        lat: (json['lat'] as num?)?.toDouble(),
        lon: (json['lon'] as num?)?.toDouble(),
        nx: (json['nx'] as num?)?.toInt(),
        ny: (json['ny'] as num?)?.toInt(),
      );
}

/// `GET /kit` — 누름 장치 세트(RPi4·모션 보드·콘센트 보드 한 묶음)의 지금 상태.
class KitStatus {
  const KitStatus({
    required this.found,
    this.kitId,
    this.motion,
    this.motionPresent = false,
    this.outlet,
    this.outletPresent = false,
    this.homed,
    this.boundAppliance,
    this.boundName,
    this.verified = false,
    this.reason,
  });

  /// 설정된 링크의 세트가 `kit_id`로 답했나.
  final bool found;
  final String? kitId;

  /// `serial`(실물) 또는 `mock`.
  final String? motion;
  final bool motionPresent;
  final String? outlet;
  final bool outletPresent;
  final bool? homed;

  /// 세트가 맡은 가전.
  final String? boundAppliance;
  final String? boundName;
  final bool verified;

  /// 물리 비상 버튼을 쓰지 않는 구성의 안내.

  /// 못 찾은 이유(본체 문장).
  final String? reason;

  factory KitStatus.fromJson(Map<String, dynamic> json) => KitStatus(
        found: json['found'] == true,
        kitId: json['kit_id'] as String?,
        motion: json['motion'] as String?,
        motionPresent: json['motion_present'] == true,
        outlet: json['outlet'] as String?,
        outletPresent: json['outlet_present'] == true,
        homed: json['homed'] as bool?,
        boundAppliance: json['bound_appliance'] as String?,
        boundName: json['name'] as String?,
        verified: json['verified'] == true,
        reason: json['reason'] as String?,
      );
}

/// `/mapping/frame` — 누름 장치가 닿는 범위(작업 영역, mm)와 원점 방향(2026-10-26).
///
/// 사용자는 mm를 적지 않는다 — 가전 추가 화면이 이 비율의 칸을 사진 위에 겹치고 사용자가 장치 자리에 끌어 맞춘다.
/// 새 본체는 `workspace`를, 옛 본체는 `frame_w_mm`·`frame_h_mm`·`y_up`을 준다. 모르면 null(설치하는 분이 정할 일).
class MappingFrame {
  const MappingFrame({this.widthMm, this.heightMm, this.yUp = false, this.note});

  final double? widthMm;
  final double? heightMm;

  /// 갠트리 Y가 위로 커지나(원점 좌하단). 처음 그릴 칸의 원점 귀퉁이를 정한다.
  final bool yUp;
  final String? note;

  bool get known => widthMm != null && heightMm != null && widthMm! > 0 && heightMm! > 0;

  /// 처음 그릴 칸의 방향 — 본체 원점이 사진의 왼쪽 아래(yUp)인지 왼쪽 위인지.
  AreaOrientation get defaultOrientation =>
      yUp ? const AreaOrientation() : const AreaOrientation(rotation: 180, flipped: true);

  factory MappingFrame.fromJson(Map<String, dynamic> json) {
    final ws = json['workspace'];
    if (ws is Map<String, dynamic>) {
      return MappingFrame(
        widthMm: (ws['w_mm'] as num?)?.toDouble(),
        heightMm: (ws['h_mm'] as num?)?.toDouble(),
        yUp: ws['y_up'] == true,
        note: json['note'] as String?,
      );
    }
    return MappingFrame(
      widthMm: (json['frame_w_mm'] as num?)?.toDouble(),
      heightMm: (json['frame_h_mm'] as num?)?.toDouble(),
      yUp: json['y_up'] == true,
      note: json['note'] as String?,
    );
  }
}

/// 누름 장치가 사진에서 놓인 방향 — 사진 위 칸을 90° 단위로 돌리고(0·90·180·270) 거울처럼 뒤집은 것.
///
/// 칸의 귀퉁이는 늘 처음 그린 순서(사진에서 왼쪽 위 → 오른쪽 위 → 오른쪽 아래 → 왼쪽 아래)로 둔다. 이 방향이 그중
/// 어느 귀퉁이가 원점이고 어느 쪽이 +X·+Y인지 정한다. 본체(`rpi/services/panel_mapping.py` `device_corner_order`)와
/// **같은 규칙**이어야 한다.
class AreaOrientation {
  const AreaOrientation({this.rotation = 0, this.flipped = false});

  final int rotation;
  final bool flipped;

  /// 칸 귀퉁이 번호 중 장치의 (원점, +X 끝, 맞은편, +Y 끝). 기본은 원점 왼쪽 아래·+X 오른쪽·+Y 위.
  List<int> get cornerOrder {
    final base = flipped ? const [2, 3, 0, 1] : const [3, 2, 1, 0];
    final r = (rotation ~/ 90) % 4;
    return [for (final i in base) (i + r) % 4];
  }

  AreaOrientation rotated() => AreaOrientation(rotation: (rotation + 90) % 360, flipped: flipped);
  AreaOrientation mirrored() => AreaOrientation(rotation: rotation, flipped: !flipped);

  Map<String, dynamic> toJson() => {'rotation': rotation, 'flipped': flipped};

  static AreaOrientation? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final r = (raw['rotation'] as num?)?.toInt() ?? 0;
    if (r % 90 != 0) return null;
    return AreaOrientation(rotation: r % 360, flipped: raw['flipped'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is AreaOrientation && other.rotation == rotation && other.flipped == flipped;

  @override
  int get hashCode => Object.hash(rotation, flipped);
}

/// 사진 좌표 한 점(px, 왼쪽 위 원점·아래로 +y).
class PhotoPoint {
  const PhotoPoint(this.x, this.y);
  final double x;
  final double y;

  List<double> toJson() => [x, y];

  static PhotoPoint? fromJson(Object? raw) {
    if (raw is List && raw.length == 2 && raw[0] is num && raw[1] is num) {
      return PhotoPoint((raw[0] as num).toDouble(), (raw[1] as num).toDouble());
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// 가전의 사진 매핑 기록 — 서버 `panel_mapping`(사진 크기·모서리·버튼 px).
///
/// 가전 상세가 사진 위에 버튼을 그릴 때 쓴다. 사진 파일 자체는 서버에 없다.
class PanelMapping {
  const PanelMapping({
    required this.photoWidth,
    required this.photoHeight,
    this.corners = const [],
    this.buttons = const {},
    this.stopPoint,
    this.parkPoint,
    this.orientation,
  });

  final double photoWidth;
  final double photoHeight;
  final List<PhotoPoint> corners;

  /// 버튼 id → 사진 px.
  final Map<String, PhotoPoint> buttons;
  final PhotoPoint? stopPoint;
  final PhotoPoint? parkPoint;

  /// 누름 장치 칸 방식으로 맞춘 매핑의 방향(2026-10-26). 옛 방식(버튼판 귀퉁이)은 null.
  final AreaOrientation? orientation;

  static PanelMapping? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final photo = raw['photo'];
    if (photo is! Map<String, dynamic>) return null;
    final w = (photo['width'] as num?)?.toDouble();
    final h = (photo['height'] as num?)?.toDouble();
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    final buttons = <String, PhotoPoint>{};
    final rawButtons = raw['buttons_px'];
    if (rawButtons is Map<String, dynamic>) {
      rawButtons.forEach((k, v) {
        final p = PhotoPoint.fromJson(v);
        if (p != null) buttons[k] = p;
      });
    }
    return PanelMapping(
      photoWidth: w,
      photoHeight: h,
      corners: [
        for (final c in (raw['corners_px'] as List<dynamic>?) ?? const [])
          if (PhotoPoint.fromJson(c) case final p?) p,
      ],
      buttons: buttons,
      stopPoint: PhotoPoint.fromJson(raw['stop_px']),
      parkPoint: PhotoPoint.fromJson(raw['park_px']),
      orientation: AreaOrientation.fromJson(raw['orientation']),
    );
  }

  Map<String, dynamic> toJson() => {
        'photo': {'width': photoWidth, 'height': photoHeight},
        'corners_px': corners.map((c) => c.toJson()).toList(),
        'buttons_px': buttons.map((k, v) => MapEntry(k, v.toJson())),
        'stop_px': stopPoint?.toJson(),
        'park_px': parkPoint?.toJson(),
        if (orientation != null) 'orientation': orientation!.toJson(),
      };
}

/// `PUT /appliances/{id}/mapping` 요청.
class MappingRequest {
  const MappingRequest({
    required this.photoWidth,
    required this.photoHeight,
    required this.corners,
    required this.buttons,
    this.frameWidthMm,
    this.frameHeightMm,
    this.stopButton,
    this.stopPresses = 1,
    this.parkPoint,
    this.expectedRevision,
    this.orientation,
  });

  final int photoWidth;
  final int photoHeight;

  /// 왼쪽 위 → 오른쪽 위 → 오른쪽 아래 → 왼쪽 아래.
  final List<PhotoPoint> corners;
  final Map<String, PhotoPoint> buttons;
  final double? frameWidthMm;
  final double? frameHeightMm;
  final String? stopButton;
  final int stopPresses;
  final PhotoPoint? parkPoint;
  final int? expectedRevision;

  /// 있으면 누름 장치 칸 방식 — [corners]는 사진 위에 맞춘 칸의 네 귀퉁이(mm는 본체가 안다).
  final AreaOrientation? orientation;

  Map<String, dynamic> toJson() => {
        'photo_width': photoWidth,
        'photo_height': photoHeight,
        'corners_px': corners.map((c) => c.toJson()).toList(),
        if (frameWidthMm != null) 'frame_w_mm': frameWidthMm,
        if (frameHeightMm != null) 'frame_h_mm': frameHeightMm,
        'buttons_px': buttons.map((k, v) => MapEntry(k, v.toJson())),
        if (stopButton != null) 'stop_button': stopButton,
        'stop_presses': stopPresses,
        if (parkPoint != null) 'park_px': parkPoint!.toJson(),
        if (expectedRevision != null) 'expected_revision': expectedRevision,
        if (orientation != null) 'orientation': orientation!.toJson(),
      };
}

/// 매핑 저장 응답에서 화면이 쓰는 것.
class MappingSaveResult {
  const MappingSaveResult({
    required this.saved,
    this.unmappedButtons = const [],
    this.stopParkStatus,
    this.stopParkNotes = const [],
    this.appliance,
  });

  final bool saved;
  final List<String> unmappedButtons;

  /// ok | unverified | incomplete | none
  final String? stopParkStatus;
  final List<String> stopParkNotes;

  /// 저장된 가전 응답(`GET /appliances` 항목과 같은 모양).
  final Map<String, dynamic>? appliance;

  factory MappingSaveResult.fromJson(Map<String, dynamic> json) {
    final check = json['stop_park_check'];
    return MappingSaveResult(
      saved: json['saved'] == true,
      unmappedButtons:
          (json['unmapped_buttons'] as List<dynamic>?)?.cast<String>() ??
              const [],
      stopParkStatus:
          check is Map<String, dynamic> ? check['status'] as String? : null,
      stopParkNotes: check is Map<String, dynamic>
          ? ((check['notes'] as List<dynamic>?)?.whereType<String>().toList() ??
              const [])
          : const [],
      appliance: json['appliance'] as Map<String, dynamic>?,
    );
  }
}

/// 확인 주행 한 칸.
class VerifyPassStep {
  const VerifyPassStep({required this.label, required this.kind, required this.status, this.detail});

  final String label;

  /// button | park
  final String kind;

  /// pending | moving | reached | failed | skipped
  final String status;
  final String? detail;

  factory VerifyPassStep.fromJson(Map<String, dynamic> json) => VerifyPassStep(
        label: json['button'] as String? ?? json['label'] as String? ?? '',
        kind: json['kind'] as String? ?? 'button',
        status: json['status'] as String? ?? 'pending',
        detail: json['detail'] as String?,
      );
}

/// 확인 주행 상태 — `GET /appliances/{id}/verify-pass`.
class VerifyPass {
  const VerifyPass({
    required this.state,
    this.steps = const [],
    this.detail,
    this.note,
    this.executionMode,
  });

  /// running | done | failed. 응답에 없거나 그 밖의 값이면 [unknownState] —
  /// 근거가 빠진 응답을 '실패'로 바꾸지 않는다(검토 M2, 2026-10-13).
  final String state;

  static const unknownState = 'unknown';
  static const knownStates = {'running', 'done', 'failed'};

  /// 서버가 running·done·failed 중 하나를 말했는가.
  bool get stateKnown => knownStates.contains(state);
  final List<VerifyPassStep> steps;
  final String? detail;
  final String? note;

  /// mock이면 **모의 주행**이다 -- 실제로 움직였다고 말하지 않는다.
  final String? executionMode;

  bool get running => state == 'running';
  bool get isMock => executionMode == 'mock';

  factory VerifyPass.fromJson(Map<String, dynamic> json) => VerifyPass(
        state: json['state'] as String? ?? unknownState,
        steps: [
          for (final s in (json['steps'] as List<dynamic>?) ?? const [])
            if (s is Map<String, dynamic>) VerifyPassStep.fromJson(s),
        ],
        detail: json['detail'] as String?,
        note: json['note'] as String?,
        executionMode: json['execution_mode'] as String?,
      );
}

/// 확인 주행 조회 결과의 종류(2026-10-13). '안 함'과 '모름'을 섞지 않는다.
enum VerifyPassLookupKind {
  /// 서버가 마지막 확인 주행을 돌려줬다([VerifyPassLookup.pass]).
  found,

  /// 서버가 **기록 없음을 명시**했다 — `404` + detail [VerifyPassLookup.noRecordDetail].
  /// 서버는 확인 주행을 메모리에만 두므로 '이 서버가 켜진 뒤 기록 없음'이다.
  noRecord,

  /// 조회 실패·로딩·일반 404·응답 해석 실패. 했는지 안 했는지 모른다.
  unknown,
}

/// 확인 주행 조회 결과 — `GET /appliances/{id}/verify-pass`.
class VerifyPassLookup {
  const VerifyPassLookup.found(VerifyPass this.pass)
      : kind = VerifyPassLookupKind.found;
  const VerifyPassLookup.noRecord()
      : kind = VerifyPassLookupKind.noRecord,
        pass = null;
  const VerifyPassLookup.unknown()
      : kind = VerifyPassLookupKind.unknown,
        pass = null;

  /// 서버(`rpi/api/mapping_router.py`)가 기록이 없을 때 보내는 detail 문장.
  /// 같은 경로의 다른 404(옛 서버의 'Not Found' 등)와 가르는 유일한 표시다.
  static const noRecordDetail = '확인 주행 기록이 없어요';

  final VerifyPassLookupKind kind;
  final VerifyPass? pass;
}
