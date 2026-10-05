import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/estop.dart';
import '../services/rpi_api_service.dart';
import 'rpi_api_provider.dart';

/// 비상정지 걸림 상태(2026-10-05) — 허브 `/status.estop_latched`를 주기적으로 읽는다.
class EstopState {
  const EstopState({
    this.latched = false,
    this.detail,
    this.acking = false,
    this.message,
  });

  final bool latched;
  final String? detail;

  /// 해제 요청을 보내고 답을 기다리는 중.
  final bool acking;

  /// 마지막 해제 시도가 실패한 이유(배너에 남긴다). 풀리면 지운다.
  final String? message;

  EstopState copyWith({
    bool? latched,
    String? detail,
    bool clearDetail = false,
    bool? acking,
    String? message,
    bool clearMessage = false,
  }) =>
      EstopState(
        latched: latched ?? this.latched,
        detail: clearDetail ? null : (detail ?? this.detail),
        acking: acking ?? this.acking,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// 걸림 조회 주기. null이면 주기 조회를 하지 않는다(테스트가 refresh()를 직접 부른다).
final estopPollIntervalProvider =
    Provider<Duration?>((_) => const Duration(seconds: 5));

class EstopNotifier extends StateNotifier<EstopState> {
  EstopNotifier(this._api, {Duration? pollInterval}) : super(const EstopState()) {
    if (_api == null) return;
    refresh();
    if (pollInterval != null) {
      _timer = Timer.periodic(pollInterval, (_) => refresh());
    }
  }

  final RpiApiService? _api;
  Timer? _timer;
  bool _inFlight = false;

  /// 허브에 걸림 여부를 묻는다. **해제 요청은 절대 보내지 않는다.**
  ///
  /// 조회 실패는 상태 변화의 증거가 아니다 — 마지막으로 안 걸림을 그대로 둔다
  /// (연결이 끊겼다고 배너를 내리면 걸린 채 실행 버튼을 누르게 된다).
  Future<void> refresh() async {
    final api = _api;
    if (api == null || _inFlight) return;
    _inFlight = true;
    try {
      final hub = await api.hubStatus();
      if (!mounted) return;
      state = hub.estopLatched
          ? state.copyWith(latched: true, detail: hub.estopDetail, clearDetail: hub.estopDetail == null)
          : state.copyWith(latched: false, clearDetail: true, clearMessage: true);
    } catch (_) {
      // 모름 — 그대로 둔다.
    } finally {
      _inFlight = false;
    }
  }

  /// 사람이 확인 대화에서 '해제'를 누른 뒤에만 부른다.
  ///
  /// 성공이면 상태를 다시 읽는다. 실패면 배너를 남기고 이유를 [EstopState.message]에 둔다.
  Future<EstopAckResult?> acknowledge() async {
    final api = _api;
    if (api == null || state.acking) return null;
    state = state.copyWith(acking: true, clearMessage: true);
    final result = await api.ackEstop();
    if (!mounted) return result;
    if (result.cleared) {
      state = const EstopState();
      await refresh();
    } else {
      state = state.copyWith(acking: false, message: result.message);
    }
    return result;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final estopProvider = StateNotifierProvider<EstopNotifier, EstopState>((ref) {
  final api = ref.watch(rpiApiServiceProvider);
  return EstopNotifier(api, pollInterval: ref.watch(estopPollIntervalProvider));
});
