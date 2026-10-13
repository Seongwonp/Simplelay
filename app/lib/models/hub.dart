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

/// `/mapping/frame` — 갠트리 프레임 안쪽 치수. 모르면(null) 사용자가 적는다.
class MappingFrame {
  const MappingFrame({this.widthMm, this.heightMm, this.note});

  final double? widthMm;
  final double? heightMm;
  final String? note;

  bool get known => widthMm != null && heightMm != null;

  factory MappingFrame.fromJson(Map<String, dynamic> json) => MappingFrame(
        widthMm: (json['frame_w_mm'] as num?)?.toDouble(),
        heightMm: (json['frame_h_mm'] as num?)?.toDouble(),
        note: json['note'] as String?,
      );
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
  });

  final double photoWidth;
  final double photoHeight;
  final List<PhotoPoint> corners;

  /// 버튼 id → 사진 px.
  final Map<String, PhotoPoint> buttons;
  final PhotoPoint? stopPoint;
  final PhotoPoint? parkPoint;

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
    );
  }

  Map<String, dynamic> toJson() => {
        'photo': {'width': photoWidth, 'height': photoHeight},
        'corners_px': corners.map((c) => c.toJson()).toList(),
        'buttons_px': buttons.map((k, v) => MapEntry(k, v.toJson())),
        'stop_px': stopPoint?.toJson(),
        'park_px': parkPoint?.toJson(),
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
