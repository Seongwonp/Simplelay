import 'dart:async';

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

class CareEventsNotifier extends StateNotifier<CareEventsState> {
  CareEventsNotifier(this._ref) : super(const CareEventsState()) {
    _init();
  }

  static const _prefsKey = 'care_events_last_seen_id';
  static const _pollInterval = Duration(seconds: 45);

  final Ref _ref;
  Timer? _timer;

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(lastSeenId: prefs.getInt(_prefsKey) ?? 0);
    await refresh();
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  Future<void> refresh() async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) return; // 서버 미설정 — 알림함은 비어 있는 채로
    final events = await api.careEvents();
    if (!mounted) return;
    state = state.copyWith(events: events);
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
    _timer?.cancel();
    super.dispose();
  }
}

final careEventsProvider =
    StateNotifierProvider<CareEventsNotifier, CareEventsState>(
  CareEventsNotifier.new,
);
