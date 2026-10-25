import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import '../models/suggestion.dart';
import '../services/rpi_api_service.dart';
import 'appliance_provider.dart';
import 'ble_provider.dart';
import 'demo_provider.dart';
import 'rpi_api_provider.dart';

const _httpPollInterval = Duration(seconds: 5);

class SuggestionNotifier extends StateNotifier<List<Suggestion>> {
  SuggestionNotifier(this.ref) : super(const []) {
    _bleSubscription =
        ref.read(bleServiceProvider).messages.listen(_onBleMessage);
    _pollHttp();
    _httpPollTimer = Timer.periodic(_httpPollInterval, (_) => _pollHttp());
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _bleSubscription;
  Timer? _httpPollTimer;

  // BLE(ESP32가 직접 밀어줌)와 HTTP(/suggestions 폴링) 출처를 분리 보관 후 합쳐서 노출한다.
  // 그래야 한쪽을 갱신할 때 다른 쪽 목록을 지우지 않는다.
  List<Suggestion> _bleSuggestions = [];
  List<Suggestion> _httpSuggestions = [];

  void _publish() {
    state = [..._bleSuggestions, ..._httpSuggestions];
  }

  void _onBleMessage(Map<String, dynamic> message) {
    if (message['type'] != 'suggestion') return;
    final suggestion = Suggestion.fromJson(message);
    _bleSuggestions = [
      ..._bleSuggestions
          .where((item) => item.sequenceId != suggestion.sequenceId),
      suggestion,
    ];
    _publish();
  }

  bool _pollInFlight = false;

  /// 지금 바로 다시 받는다. 루틴 '지금 실행'이 카드를 만든 직후처럼, 다음
  /// 5초 폴링을 기다리면 사용자가 빈 확인 화면을 보게 되는 경우에 쓴다.
  Future<void> refresh() => _pollHttp();

  Future<void> _pollHttp() async {
    // 재진입 가드 — 5초 주기 폴링 vs 8초 타임아웃이라 서버가 느리면
    // 요청이 겹겹이 쌓일 수 있다.
    if (_pollInFlight) return;
    _pollInFlight = true;
    try {
      await _pollHttpOnce();
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _pollHttpOnce() async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      if (_httpSuggestions.isNotEmpty) {
        _httpSuggestions = [];
        _publish();
      }
      return;
    }
    try {
      final remote = await api.suggestions();
      // **설치된 가전**에서만 찾는다. 현재 선택 가전으로 메우지 않는다.
      final installed = ref.read(installedAppliancesProvider);
      final previous = {for (final s in _httpSuggestions) s.sequenceId: s};
      _httpSuggestions = remote
          .map((r) => _toSuggestion(
                r,
                _applianceFor(r, installed),
                previous[r.id]?.receivedAt,
              ))
          .toList();
      _publish();
    } catch (_) {
      // 네트워크 오류 시 이전 목록 유지 — 다음 폴링에서 재시도.
    }
  }

  /// 제안이 조작할 **그 가전**. 못 찾으면 null이다.
  ///
  /// 현재 선택 가전으로 메우지 않는다. 전자레인지를 고른 상태에서 냉방
  /// 제안이 전자레인지 지도를 달고 나오면, 화면과 실제 실행 대상이
  /// 어긋난다 -- 그건 조용한 거짓말이다.
  ///
  /// null이 되는 경우는 둘이다.
  /// - 서버가 대상을 모른다(가전 없이 쌓인 옛 이력)
  /// - 그 가전이 이 폰에서 지워졌다
  ///
  /// 어느 쪽이든 **실행을 막아야 하는 상태**고, 화면이 그 사실을 말한다.
  ApplianceMap? _applianceFor(RpiSuggestion r, List<ApplianceMap> installed) {
    final id = r.applianceId;
    if (id == null) return null;
    return installed.where((a) => a.id == id).firstOrNull;
  }

  // RPi 백엔드는 버튼을 라벨 문자열("해동")로 돌려주지만, 이 화면 트리는
  // BLE 관례대로 버튼 코드("BT-08")를 기준으로 매칭·표시한다.
  // 대상 가전의 버튼맵으로 라벨→코드 역매핑한다. 대상을 모르면 라벨을
  // 그대로 둔다 -- 다른 가전의 코드를 붙이면 화면이 틀린 버튼을 가리킨다.
  Suggestion _toSuggestion(
    RpiSuggestion r,
    ApplianceMap? appliance,
    DateTime? receivedAt,
  ) {
    final steps = r.steps.map((label) {
      final match =
          appliance?.buttons.where((btn) => btn.label == label).firstOrNull;
      return match?.id ?? label;
    }).toList();
    return Suggestion(
      sequenceId: r.id,
      label: r.purpose,
      steps: steps,
      receivedAt: receivedAt ?? DateTime.now(),
      source: SuggestionSource.http,
      reason: r.reason,
      applianceId: r.applianceId,
      timeBand: r.timeBand,
      occurrences: r.occurrences,
      isDemo: r.isDemo,
      scenarioId: r.scenarioId,
      routineId: r.routineId,
      routineName: r.routineName,
      autoRuleOffer: r.autoRuleOffer,
      signals: r.signals,
      canMarkDone: r.canMarkDone,
      commands: [
        for (final c in r.commands)
          SuggestionCommand(
            targetId: c.targetId,
            route: c.route,
            action: c.action,
            buttons: c.buttons,
            summary: c.summary,
          ),
      ],
    );
  }

  /// 승인 재검사 실패(409) 뒤 — 서버가 카드를 내렸으니 로컬에서도 지우고 곧바로
  /// 다시 받는다. 다음 5초 폴링을 기다리면 사용자가 옛 카드를 또 누를 수 있다.
  Future<void> refreshAfterApprovalChanged(String suggestionId) async {
    _httpSuggestions =
        _httpSuggestions.where((s) => s.sequenceId != suggestionId).toList();
    _publish();
    await _pollHttp();
  }

  void add(Suggestion suggestion) {
    // Legacy BLE insertion; HTTP revision responses use replaceHttp below.
    _bleSuggestions = [
      ..._bleSuggestions
          .where((item) => item.sequenceId != suggestion.sequenceId),
      suggestion,
    ];
    _publish();
  }

  void replaceHttp(String previousId, RpiSuggestion revised) {
    final installed = ref.read(installedAppliancesProvider);
    _httpSuggestions = [
      ..._httpSuggestions.where((s) => s.sequenceId != previousId && s.sequenceId != revised.id),
      _toSuggestion(revised, _applianceFor(revised, installed), null),
    ];
    _publish();
  }

  Future<void> respond(Suggestion suggestion, bool approved) async {
    if (suggestion.source == SuggestionSource.http) {
      // HTTP 승인/거부 호출은 화면(suggestion_screen.dart)에서 이미 끝냈다 —
      // 여기서는 다음 폴링을 기다리지 않고 로컬 목록에서 즉시 제거만 한다.
      _httpSuggestions = _httpSuggestions
          .where((item) => item.sequenceId != suggestion.sequenceId)
          .toList();
      _publish();
      return;
    }
    // 모의 실행에서는 BLE로도 나가지 않는다. HTTP만 막으면 BLE로 붙은
    // 실기기가 실제로 움직이는데 화면은 "실제 조작이 아닙니다"라고 한다.
    // 거절(approved=false)은 물리 동작이 아니므로 그대로 보낸다.
    if (!(approved && ref.read(demoModeProvider))) {
      await ref
          .read(bleServiceProvider)
          .sendConfirmation(suggestion.sequenceId, approved);
    }
    _bleSuggestions = _bleSuggestions
        .where((item) => item.sequenceId != suggestion.sequenceId)
        .toList();
    _publish();
  }

  @override
  void dispose() {
    _bleSubscription?.cancel();
    _httpPollTimer?.cancel();
    super.dispose();
  }
}

final suggestionProvider =
    StateNotifierProvider<SuggestionNotifier, List<Suggestion>>(
  SuggestionNotifier.new,
);
