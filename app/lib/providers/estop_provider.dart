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
    this.holdState,
    this.hubRunning = false,
    this.hubJobId,
    this.hubLastJobId,
    this.localGate,
  });

  final bool latched;

  /// 마지막으로 **성공한** `/status`의 로컬 실행 대상 신호(걸림·링크, `HubStatus.localGate`).
  /// 아직 못 받았으면 null, 조회 실패·해제 직후에도 그대로 둔다. 홈이 이 변화를 듣고
  /// 가전 목록의 준비 판정을 다시 받는다(검토 M1, 2026-10-13).
  final ({bool? estop, bool? linkUp})? localGate;
  final String? detail;

  /// 해제 요청을 보내고 답을 기다리는 중.
  final bool acking;

  /// 마지막 해제 시도가 실패한 이유(배너에 남긴다). 풀리면 지운다.
  final String? message;

  /// 같은 `/status` 응답의 정지 버튼 대기 상태(`hold_state`, 2026-10-07 음성 정지).
  /// hovering_stop이면 실행은 끝났어도 '멈춰'를 듣는다. **조회 실패 때는 지운다** —
  /// 모르는 채 마이크를 열어 두지 않는다(10/8 인계 5차 §2).
  final String? holdState;

  /// 같은 응답의 `running` — 키오스크·루틴이 시작한 실행도 포함한다. 조회 실패면 false.
  final bool hubRunning;

  /// 같은 응답의 `job_id`·`last_job_id`(10/8 리뷰) — 음성 정지가 실행이 바뀐 것을
  /// 안다. 조회 실패면 null. 이 값은 5초 조회 주기만큼 늦다.
  final String? hubJobId;
  final String? hubLastJobId;

  /// 정지 버튼 위에서 기다리는 중 — 정지 요청이 그 버튼 누름으로 간다.
  bool get holdingAtStop => holdState == 'hovering_stop';

  EstopState copyWith({
    bool? latched,
    String? detail,
    bool clearDetail = false,
    bool? acking,
    String? message,
    bool clearMessage = false,
    String? holdState,
    bool clearHold = false,
    bool? hubRunning,
    String? hubJobId,
    String? hubLastJobId,
    bool clearJobs = false,
    ({bool? estop, bool? linkUp})? localGate,
  }) =>
      EstopState(
        localGate: localGate ?? this.localGate,
        latched: latched ?? this.latched,
        detail: clearDetail ? null : (detail ?? this.detail),
        acking: acking ?? this.acking,
        message: clearMessage ? null : (message ?? this.message),
        holdState: clearHold ? null : (holdState ?? this.holdState),
        hubRunning: hubRunning ?? this.hubRunning,
        hubJobId: clearJobs ? null : (hubJobId ?? this.hubJobId),
        hubLastJobId: clearJobs ? null : (hubLastJobId ?? this.hubLastJobId),
      );
}

/// 걸림 조회 주기. null이면 주기 조회를 하지 않는다(테스트가 refresh()를 직접 부른다).
final estopPollIntervalProvider =
    Provider<Duration?>((_) => const Duration(seconds: 5));

class EstopNotifier extends StateNotifier<EstopState> {
  EstopNotifier(this._api, {Duration? pollInterval, this.onPoll})
      : super(const EstopState()) {
    if (_api == null) return;
    refresh();
    if (pollInterval != null) {
      _timer = Timer.periodic(pollInterval, (_) => refresh());
    }
  }

  final RpiApiService? _api;

  /// 조회마다 허브에 닿았는지 알린다(평가 M2) — 연결 상태가 허브 전원 끊김·복구를 따라오게.
  /// 허브가 오류 코드로 답한 것(RpiApiException)은 닿은 것이다.
  final void Function(bool reachable)? onPoll;
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
      onPoll?.call(true);
      final next = hub.estopLatched
          ? state.copyWith(latched: true, detail: hub.estopDetail, clearDetail: hub.estopDetail == null)
          : state.copyWith(latched: false, clearDetail: true, clearMessage: true);
      state = next.copyWith(
        holdState: hub.holdState,
        clearHold: hub.holdState == null,
        hubRunning: hub.running,
        clearJobs: true,
      ).copyWith(
          hubJobId: hub.jobId,
          hubLastJobId: hub.lastJobId,
          localGate: hub.localGate);
    } catch (e) {
      // 허브가 답했으면(오류 코드·해석 실패) 닿은 것, 키 거절(401)은 연결 판정에 맡기고 알리지 않는다.
      if (mounted && !(e is RpiApiException && e.statusCode == 401)) {
        onPoll?.call(e is RpiApiException || e is FormatException);
      }
      // 걸림은 모름 — 그대로 둔다(위 이유). 대기·실행 중은 음성 정지 듣기에만 쓰여서
      // 모를 때 끄는 쪽이 안전하다(10/8 인계 5차 §2) — 정지 버튼은 그대로 있다.
      if (mounted) {
        state = state.copyWith(
            clearHold: true, hubRunning: false, clearJobs: true);
      }
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
      // 마지막으로 안 걸림·링크 신호는 남긴다 — 비워 두면 다음 조회의 변화(걸림→풀림)를
      // 가전 목록이 놓친다(검토 M1).
      state = EstopState(localGate: state.localGate);
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
  return EstopNotifier(
    api,
    pollInterval: ref.watch(estopPollIntervalProvider),
    // 기존 주기 조회의 성공/실패를 연결 상태에 반영한다(평가 M2). 새 조회를 만들지 않는다.
    onPoll: (reachable) =>
        ref.read(rpiConnectionProvider.notifier).reportHubPoll(reachable: reachable),
  );
});
