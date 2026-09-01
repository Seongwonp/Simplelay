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
class CareEventsState {
  const CareEventsState({
    this.events = const [],
    this.lastSeenId = 0,
  });

  final List<RpiCareEvent> events;
  final int lastSeenId;

  int get unreadCount =>
      events.where((e) => e.id > lastSeenId).length;

  CareEventsState copyWith({List<RpiCareEvent>? events, int? lastSeenId}) =>
      CareEventsState(
        events: events ?? this.events,
        lastSeenId: lastSeenId ?? this.lastSeenId,
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
  bool _refreshing = false;

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

  Future<void> refresh() async {
    if (_refreshing) return; // 화면 진입 refresh와 타이머 refresh의 역전 방지
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) return; // 서버 미설정 — 알림함은 비어 있는 채로
    _refreshing = true;
    try {
      final events = await api.careEvents();
      if (!mounted) return;
      // null = 통신 실패 — 보고 있던 알림·배지를 지우지 않는다 (교차 리뷰 #13)
      if (events != null) {
        state = state.copyWith(events: events);
      }
    } finally {
      _refreshing = false;
    }
  }

  /// 알림함 화면을 연 순간 호출 — 지금 보이는 것까지를 읽음 처리.
  Future<void> markAllSeen() async {
    if (state.events.isEmpty) return;
    final newest = state.events.first.id;
    if (newest <= state.lastSeenId) return;
    state = state.copyWith(lastSeenId: newest);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, newest);
    } catch (_) {
      // 저장 실패 — 세션 내 읽음 표시는 유지된다
    }
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
