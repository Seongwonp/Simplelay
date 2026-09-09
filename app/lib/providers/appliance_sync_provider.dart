import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appliance_provider.dart';
import 'rpi_api_provider.dart';

/// 이 폰에서 사용자가 지웠지만 아직 서버에 전달하지 못한 가전 id.
const _kPendingDeletesKey = 'pending_appliance_deletes';

/// 동기화 한 번의 결과 — 사용자에게 무슨 일이 있었는지 말하기 위한 값이다.
class ApplianceSyncResult {
  const ApplianceSyncResult({
    this.uploaded = 0,
    this.uploadFailed = 0,
    this.adopted = 0,
    this.deleted = 0,
    this.stillPendingDeletes = 0,
    this.serverUnreachable = false,
  });

  /// 이 폰의 가전을 서버에 올린 수.
  final int uploaded;
  final int uploadFailed;

  /// 서버에만 있어서 이 폰이 새로 받아 온 가전 수(다른 폰이 등록한 것).
  final int adopted;

  /// 밀려 있던 삭제 중 이번에 전달된 수.
  final int deleted;
  final int stillPendingDeletes;

  /// 목록 조회 자체가 실패했다 — 병합을 건너뛴 것이지 "서버가 비었다"가 아니다.
  final bool serverUnreachable;

  bool get allDone =>
      uploadFailed == 0 && stillPendingDeletes == 0 && !serverUnreachable;
}

/// 가전 동기화 — **이 폰이 명시적으로 지운 것만** 서버에서 지운다.
///
/// 예전 동기화는 "폰이 원본"이라는 가정 위에 있었다. 서버에 있는데 이 폰에
/// 없는 커스텀 가전을 전부 유령으로 보고 지웠다. 보호자 폰이 둘이면 A의
/// 동기화가 B의 등록을 지운다 — 서버 목록에만 있다는 것은 "지워도 된다"가
/// 아니라 **"이 폰이 아직 못 받았다"** 는 뜻이다.
///
/// 그래서 두 방향을 갈랐다:
/// - **올리기**: 이 폰의 가전을 서버에 upsert 한다.
/// - **내려받기**: 서버에만 있는 가전은 지우지 않고 이 폰 목록에 더한다.
/// - **지우기**: 사용자가 이 폰에서 지운 것만. 전송이 실패하면 그 사실을
///   기기에 남겨 두었다가(tombstone) 다음 동기화에서 다시 보낸다. 성공한
///   것만 대기열에서 뺀다.
class ApplianceSyncNotifier extends StateNotifier<Set<String>> {
  ApplianceSyncNotifier(this._ref) : super(const {}) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = (prefs.getStringList(_kPendingDeletesKey) ?? const []).toSet();
    } catch (_) {
      // 대기열을 못 읽어도 동기화 자체는 동작해야 한다.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPendingDeletesKey, state.toList());
    } catch (_) {}
  }

  /// 사용자가 이 폰에서 가전을 지웠다.
  ///
  /// 폰 삭제는 무조건 성립한다(사용자가 지시한 일이다). 서버 전송이 실패하면
  /// 그 사실만 남겨 두고, 다음 동기화가 다시 보낸다 — 예전에는 이 실패를
  /// 스낵바로만 알리고 잊어버려서, 복구가 "서버에만 있는 건 다 지운다"는
  /// 위험한 방식에 얹혀 있었다.
  Future<bool> deleteAppliance(String applianceId) async {
    await _ref.read(customAppliancesProvider.notifier).remove(applianceId);
    final api = _ref.read(rpiApiServiceProvider);
    final removed =
        api == null ? false : await api.deleteAppliance(applianceId);
    if (!removed) {
      state = {...state, applianceId};
      await _persist();
    }
    return removed;
  }

  /// 올리기 → 밀린 삭제 재전송 → 내려받기(병합).
  Future<ApplianceSyncResult> sync() async {
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) {
      return ApplianceSyncResult(
        stillPendingDeletes: state.length,
        serverUnreachable: true,
      );
    }

    final locals = _ref.read(customAppliancesProvider);
    var uploaded = 0;
    var uploadFailed = 0;
    for (final appliance in locals) {
      if (await api.registerAppliance(appliance)) {
        uploaded++;
      } else {
        uploadFailed++;
      }
    }

    // 밀린 삭제. 성공한 것만 대기열에서 뺀다 — 실패한 것을 지우면 서버에
    // 유령이 남은 채로 "다 됐다"고 말하게 된다.
    var deleted = 0;
    final stillPending = <String>{};
    for (final id in state) {
      if (await api.deleteAppliance(id)) {
        deleted++;
      } else {
        stillPending.add(id);
      }
    }
    if (stillPending.length != state.length) {
      state = stillPending;
      await _persist();
    }

    // 내려받기. 조회에 실패하면 병합을 건너뛴다 — 빈 목록으로 오해하면
    // 다른 폰의 가전을 "없는 것"으로 취급하게 된다.
    final remote = await api.customAppliances();
    if (remote == null) {
      return ApplianceSyncResult(
        uploaded: uploaded,
        uploadFailed: uploadFailed,
        deleted: deleted,
        stillPendingDeletes: stillPending.length,
        serverUnreachable: true,
      );
    }

    final knownIds = locals.map((a) => a.id).toSet();
    final adoptable = [
      for (final a in remote)
        // 아직 못 지운 것은 도로 받아오지 않는다 — 사용자가 지운 가전이
        // 동기화 때마다 되살아나면 지운 것이 아니다.
        if (!knownIds.contains(a.id) && !stillPending.contains(a.id)) a,
    ];
    for (final appliance in adoptable) {
      await _ref.read(customAppliancesProvider.notifier).add(appliance);
    }

    return ApplianceSyncResult(
      uploaded: uploaded,
      uploadFailed: uploadFailed,
      adopted: adoptable.length,
      deleted: deleted,
      stillPendingDeletes: stillPending.length,
    );
  }
}

final applianceSyncProvider =
    StateNotifierProvider<ApplianceSyncNotifier, Set<String>>(
  ApplianceSyncNotifier.new,
);

/// 동기화할 것이 남아 있는가 — 버튼을 보일지 정하는 조건.
///
/// 커스텀 가전 존재만으로 판단하면, **마지막 가전을 지우다 실패했을 때**
/// 버튼이 함께 사라져 복구할 길이 없어진다.
final hasPendingSyncProvider = Provider<bool>((ref) {
  final hasCustom = ref.watch(customAppliancesProvider).isNotEmpty;
  final hasPendingDeletes = ref.watch(applianceSyncProvider).isNotEmpty;
  return hasCustom || hasPendingDeletes;
});
