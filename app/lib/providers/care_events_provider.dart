import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/rpi_api_service.dart';
import 'rpi_api_provider.dart';

/// 보호자 알림함 상태 — 목록 + 안 읽은 개수.
///
/// 실패·위험소리·긴급정지·안부 신호가 키오스크(가전 옆)에만 뜨면 정작
/// 걱정하는 보호자는 모른다. 폰이 이 목록을 주기적으로 당겨와(45초)
/// 홈의 종 아이콘에 안 읽은 개수를 표시한다. "읽음"의 기준은 알림함
/// 화면을 연 시점의 최신 이벤트 id — 기기 로컬에 저장해 재시작에도 유지.
/// 알림함을 **한 번이라도 확인했는지**를 구분한다.
///
/// 예전에는 목록 하나뿐이라, 통신이 끊겨 못 받은 화면이 "아직 알림이
/// 없어요"라고 단언했다. 이 알림함이 다루는 것은 실행 실패·위험 신호음·
/// 안부 신호다 — 못 본 것을 "아무 일 없다"로 읽으면 기능의 이유가 무너진다.
enum CareInboxStatus {
  /// 아직 첫 조회가 끝나지 않았다.
  loading,

  /// 최소 한 번 받아왔다. events가 비어 있으면 **정말로 0건**이다.
  ready,

  /// 마지막 시도가 실패했다. events는 직전에 받아둔 것일 수 있다.
  failed,

  /// 서버 주소가 없다 — 실패가 아니라 물어볼 곳이 없는 것이다.
  unconfigured,
}

class CareEventsState {
  const CareEventsState({
    this.events = const [],
    this.lastSeenId = 0,
    this.status = CareInboxStatus.loading,
    this.lastLoadedAt,
    this.acks = const PersonAcks(),
  });

  final List<RpiCareEvent> events;
  final int lastSeenId;

  /// 본체에 적힌 '사람이 확인함'(2026-10-19) — 다른 기기(키오스크 지난 일 확인·답)에서 본 것도 여기 있다.
  /// 이 폰의 [lastSeenId]와 함께 본다: 둘 중 하나라도 봤다고 하면 안 본 알림이 아니다.
  final PersonAcks acks;
  final CareInboxStatus status;

  /// 마지막으로 **성공한** 조회 시각. 실패해도 그대로 둔다 — 화면이
  /// "언제까지의 정보인지"를 말할 수 있어야 한다.
  final DateTime? lastLoadedAt;

  bool _unread(RpiCareEvent e) => e.id > lastSeenId && !acks.covers(e);

  int get unreadCount => events.where(_unread).length;

  /// 아직 안 본 알림 — 이 폰에서 알림함을 연 뒤 새로 왔고, 어느 기기에서도 확인하지 않은 것(본체 확인, 2026-10-19:
  /// '기록 보기'로 못 한 일을 보고 와도 경고가 남았고, 키오스크에서 확인한 실패도 폰에 남았다).
  List<RpiCareEvent> get unreadEvents => [for (final e in events) if (_unread(e)) e];

  CareEventsState copyWith({
    List<RpiCareEvent>? events,
    int? lastSeenId,
    CareInboxStatus? status,
    DateTime? lastLoadedAt,
    PersonAcks? acks,
  }) =>
      CareEventsState(
        events: events ?? this.events,
        lastSeenId: lastSeenId ?? this.lastSeenId,
        status: status ?? this.status,
        lastLoadedAt: lastLoadedAt ?? this.lastLoadedAt,
        acks: acks ?? this.acks,
      );
}

class CareEventsNotifier extends StateNotifier<CareEventsState>
    with WidgetsBindingObserver {
  CareEventsNotifier(this._ref) : super(const CareEventsState()) {
    _init();
  }

  static const _prefsKey = 'care_events_last_seen_id';
  static const _pollInterval = Duration(seconds: 45);

  final Ref _ref;
  Timer? _timer;

  /// 진행 중인 조회. 겹쳐 부른 쪽은 **이것을 기다린다** — 그냥 반환하면
  /// 화면 진입 시 읽음 처리가 아직 비어 있는 목록 위에서 돌아 아무것도
  /// 읽음이 안 된다.
  Future<void>? _inFlight;

  Future<void> _init() async {
    // 백그라운드에서는 폴링을 멈춘다 — OS가 어차피 타이머를 지연시키고,
    // 불필요한 network wake-up만 만든다. 복귀 시 즉시 새로고침 (교차 리뷰
    // #14). 이 폴링은 "앱을 열면 확인"하는 알림함이지 실시간 푸시가
    // 아니다 — 원격 실시간 알림은 FCM 등 별도 인프라가 필요해 범위 밖.
    WidgetsBinding.instance.addObserver(this);
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(lastSeenId: prefs.getInt(_prefsKey) ?? 0);
    await refresh();
    _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh();
      _startPolling();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() {
    // 화면 진입 refresh와 45초 타이머 refresh가 겹칠 수 있다. 요청은 한 번만
    // 내되, 늦게 부른 쪽도 **완료를 기다리게** 한다.
    final running = _inFlight;
    if (running != null) return running;
    final started = _refresh();
    _inFlight = started;
    return started.whenComplete(() {
      if (identical(_inFlight, started)) _inFlight = null;
    });
  }

  Future<void> _refresh() async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) {
      // 실패가 아니다 — 물어볼 곳이 없는 것이다. 화면이 "불러오지 못했어요"
      // 대신 "기기와 연결되면 여기에 표시돼요"라고 말할 수 있어야 한다.
      if (mounted) state = state.copyWith(status: CareInboxStatus.unconfigured);
      return;
    }
    final (events, acks) = await (api.careEvents(), api.acks()).wait;
    if (!mounted) return;
    // 확인 표시는 받았을 때만 바꾼다(옛 본체·통신 실패면 직전 값 그대로 — 지우지도 지어내지도 않는다).
    if (acks != null) state = state.copyWith(acks: acks);
    if (events == null) {
      // 통신 실패 — 보고 있던 알림·배지를 지우지 않는다 (교차 리뷰 #13).
      // 다만 "지금 보고 있는 것이 최신이 아니다"는 사실은 알린다.
      state = state.copyWith(status: CareInboxStatus.failed);
      return;
    }
    state = state.copyWith(
      events: events,
      status: CareInboxStatus.ready,
      lastLoadedAt: DateTime.now(),
      lastSeenId: _rewoundSeenId(events),
    );
  }

  /// 서버 DB가 새로 만들어지면 이벤트 id가 1부터 다시 시작한다. 예전
  /// lastSeenId(예: 50)를 그대로 두면 **새 알림 전부가 영구히 '읽음'** 이
  /// 된다 — 배지가 영영 안 뜨는 알림함이 되는 것이다.
  ///
  /// 가장 큰 id가 기준보다 작아지면 id 공간이 갈린 것으로 보고 되감는다.
  int _rewoundSeenId(List<RpiCareEvent> events) {
    if (events.isEmpty || state.lastSeenId == 0) return state.lastSeenId;
    final newest =
        events.map((e) => e.id).reduce((a, b) => a > b ? a : b);
    return newest < state.lastSeenId ? 0 : state.lastSeenId;
  }

  /// 알림함 화면을 연 순간 호출 — 지금 보이는 것까지를 읽음 처리. 본체에도 적어 다른 기기에서도 사라진다(2026-10-19).
  Future<void> markAllSeen() async {
    if (state.events.isEmpty) return;
    final newest = state.events.first.id;
    if (newest <= state.lastSeenId && newest <= state.acks.careSeenId) return;
    if (newest > state.lastSeenId) {
      state = state.copyWith(lastSeenId: newest);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_prefsKey, newest);
      } catch (_) {
        // 저장 실패 — 세션 내 읽음 표시는 유지된다
      }
    }
    final acks = await _ref.read(rpiApiServiceProvider)?.postAcks(careSeenId: newest);
    if (acks != null && mounted) state = state.copyWith(acks: acks);
  }

  /// 못 한 일을 봤다(홈 경고의 '기록 보기', 2026-10-19) — 본체에 적어 폰 경고·설정 탭 배지·키오스크 표시가 함께 사라진다.
  /// 본체 시계로 지금까지의 못 한 일만 — 위험 소리·비상 정지·안부 신호는 알림함을 열어야 지워진다. 새 실패는 다시 뜬다.
  /// 본체에 닿지 못하면 아무것도 지우지 않는다(확인을 지어내지 않는다).
  Future<bool> markFailuresSeen() async {
    final acks = await _ref.read(rpiApiServiceProvider)?.postAcks(failuresSeen: true);
    if (acks == null || !mounted) return false;
    state = state.copyWith(acks: acks);
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}

final careEventsProvider =
    StateNotifierProvider<CareEventsNotifier, CareEventsState>(
  CareEventsNotifier.new,
);
