import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rpi_api_provider.dart';

/// 안부 확인을 쉬는 종료 날짜. null이면 쉬지 않는다.
///
/// **제안 DND와 다른 것이다.** DND는 "지금 말 걸지 마"(분 단위)이고, 이건
/// "며칠간 조용한 게 정상이다"(날짜)이다. 하나로 묶으면 방해 금지 30분이
/// 안부 확인까지 꺼버리거나, 여행 일주일이 제안까지 막는다.
///
/// 서버가 진실원천이다 — 안부 신호를 만드는 쪽이 서버이기 때문이다. 폰은
/// 조회하고 바꾸기만 한다.
class WellnessPauseNotifier extends StateNotifier<DateTime?> {
  WellnessPauseNotifier(this._ref) : super(null);

  final Ref _ref;

  Future<void> refresh() async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) return;
    final until = await api.wellnessPause();
    if (mounted) state = until;
  }

  /// [until]까지(그날 포함) 쉰다. 실패하면 false — 화면이 "쉬는 중"이라고
  /// 잘못 말하지 않도록 상태를 바꾸지 않는다.
  Future<bool> pauseUntil(DateTime until) async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) return false;
    final saved = await api.setWellnessPause(until);
    if (saved == null) return false;
    if (mounted) state = saved;
    return true;
  }

  Future<bool> clear() async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) return false;
    if (!await api.clearWellnessPause()) return false;
    if (mounted) state = null;
    return true;
  }
}

final wellnessPauseProvider =
    StateNotifierProvider<WellnessPauseNotifier, DateTime?>(
  WellnessPauseNotifier.new,
);
