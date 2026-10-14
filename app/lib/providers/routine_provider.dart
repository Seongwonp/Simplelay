import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auto_rule.dart';
import '../models/routine.dart';
import 'rpi_api_provider.dart';

/// 서버에 없는 상태(주소 미설정). 빈 목록과 구분한다 -- "루틴이 없어요"와
/// "허브에 닿지 않아요"는 사용자가 할 일이 다르다.
class RoutinesUnavailable implements Exception {
  const RoutinesUnavailable();
}

/// 내 루틴 목록. 저장·삭제·켜기 뒤에는 `ref.invalidate`로 다시 받는다.
final routinesProvider = FutureProvider.autoDispose<List<Routine>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) throw const RoutinesUnavailable();
  return api.routines();
});

/// 예시 루틴(미리 만든 템플릿) — **사용자 데이터가 아니다.** 고쳐서 저장해야 루틴이 된다.
final routineTemplatesProvider =
    FutureProvider.autoDispose<List<Routine>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) throw const RoutinesUnavailable();
  return api.routineTemplates();
});

/// 자동 실행 허용 규칙(2026-10-13). 조회 실패·옛 서버(404)는 빈 목록 — 루틴 목록을 막지 않는다.
final autoRulesProvider = FutureProvider.autoDispose<List<AutoRule>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const [];
  try {
    return await api.autoRules();
  } catch (_) {
    return const [];
  }
});

/// "다음 실행" — 켜진 시각 루틴의 가장 가까운 한 건. 없거나 실패면 null.
final nextRoutineProvider =
    FutureProvider.autoDispose<RoutineNextRun?>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return null;
  try {
    final runs = await api.nextRoutines(limit: 1);
    return runs.firstOrNull;
  } catch (_) {
    return null;
  }
});
