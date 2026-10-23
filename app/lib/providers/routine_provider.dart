import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auto_rule.dart';
import '../models/routine.dart';
import '../models/routine_candidate.dart';
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

/// 새 자동 실행 화면에서는 조회 실패를 '허용한 조건 없음'으로 숨기지 않는다.
final automationRulesProvider = FutureProvider.autoDispose<List<AutoRule>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) throw const RoutinesUnavailable();
  return api.autoRules();
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

/// 묻지 않고 하는(자동으로 하기가 켜진) 시각 루틴의 id — 루틴 목록 줄의 '자동으로 해요' 표시(평가 10차 10/18:
/// 홈 '다음' 카드에는 붙는데 루틴 목록에는 없었다). 근거는 홈과 같은 본체 `/routines/next`의 `auto` 값뿐이다 —
/// 루틴마다 가까운 회차 한 건씩 오므로 넉넉히(서버 상한 10) 받는다. 조회 실패는 빈 집합(표시를 붙이지 않는다).
final autoRoutineIdsProvider = FutureProvider.autoDispose<Set<String>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const {};
  try {
    final runs = await api.nextRoutines(limit: 10);
    return {for (final r in runs) if (r.auto && !r.quietSkip && r.routineId.isNotEmpty) r.routineId};
  } catch (_) {
    return const {};
  }
});

/// 사용 기록으로 만든 루틴 초안(2026-10-14). 조회 실패·옛 서버(404)·연결 없음은 빈 목록 —
/// 조용히 사라질 뿐 루틴 목록을 막지 않는다.
final routineCandidatesProvider =
    FutureProvider.autoDispose<List<RoutineCandidate>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const [];
  try {
    return await api.routineCandidates();
  } catch (_) {
    return const [];
  }
});
