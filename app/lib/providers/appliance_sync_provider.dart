import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';
import '../services/rpi_api_service.dart';
import 'appliance_provider.dart';
import 'rpi_api_provider.dart';
import 'server_appliance_provider.dart';

/// 아직 서버에 전달하지 못한 변경들. **순서가 있는 목록**이다.
const _kOutboxKey = 'appliance_sync_outbox';

enum SyncOpKind { upsert, delete }

/// 서버로 보내야 하는 변경 하나.
///
/// `payload`가 있는 이유: id만 남기면 **로컬에서 지운 뒤의 재전송을 복구할
/// 수 없다.** 보낼 내용이 어디에도 없기 때문이다. 그래서 등록/수정은 그
/// 시점의 정의를 통째로 스냅샷해 둔다.
class SyncOperation {
  const SyncOperation({
    required this.opId,
    required this.applianceId,
    required this.kind,
    required this.createdAt,
    this.payload,
    int revision = 0,
  }) : _revision = revision;

  final String opId;
  final String applianceId;
  final SyncOpKind kind;
  final DateTime createdAt;

  /// upsert일 때 보낼 가전 정의 스냅샷. delete는 null.
  final Map<String, dynamic>? payload;

  final int _revision;

  /// 이 작업을 만들 때 **내가 보고 있던** 서버 판 번호.
  ///
  /// 삭제에도 있어야 한다. 없으면 폰 A의 오래된 삭제가 폰 B의 방금 수정을
  /// 무조건 지운다 -- "충돌은 서버 내용 유지"가 수정에만 걸린 반쪽 계약이
  /// 된다. 0이면 모른다(구버전 대기열에서 옮겨온 것) -- 그때는 밝히지 않고
  /// 보내 종전 동작을 유지한다.
  int get expectedRevision =>
      (payload?['revision'] as num?)?.toInt() ?? _revision;

  ApplianceMap? get appliance =>
      payload == null ? null : ApplianceMap.fromJson(payload!);

  Map<String, dynamic> toJson() => {
        'op_id': opId,
        'appliance_id': applianceId,
        'kind': kind.name,
        'created_at': createdAt.toIso8601String(),
        if (payload != null) 'payload': payload,
        if (_revision > 0) 'revision': _revision,
      };

  static SyncOperation? fromJson(Map<String, dynamic> json) {
    final kind = SyncOpKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) return null; // 모르는 종류는 조용히 버린다(앞으로의 형식)
    return SyncOperation(
      opId: json['op_id'] as String,
      applianceId: json['appliance_id'] as String,
      kind: kind,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
              DateTime.now(),
      payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 동기화 한 번의 결과 — 사용자에게 무슨 일이 있었는지 말하기 위한 값이다.
class ApplianceSyncResult {
  const ApplianceSyncResult({
    this.sent = 0,
    this.failed = 0,
    this.conflicts = 0,
    this.adopted = 0,
    this.serverUnreachable = false,
  });

  /// 서버에 전달된 변경 수.
  final int sent;

  /// 전달하지 못해 대기열에 남은 수.
  final int failed;

  /// 다른 기기가 먼저 바꿔 서버 내용을 가져온 수.
  final int conflicts;

  /// 서버에만 있어서 새로 받아 온 가전 수(다른 폰이 등록한 것).
  final int adopted;

  /// 목록 조회 자체가 실패했다 — 병합을 건너뛴 것이지 "서버가 비었다"가 아니다.
  final bool serverUnreachable;

  bool get allDone => failed == 0 && !serverUnreachable;
}

/// 대기열 상태 — 화면이 "몇 건 남았는지"만 알면 되도록 최소로 노출한다.
class ApplianceSyncState {
  const ApplianceSyncState({this.pending = const [], this.lastFailed = false});

  final List<SyncOperation> pending;

  /// 마지막 시도에서 실패가 있었나. 대기만 하는 상태와 구분해 문구를 가른다.
  final bool lastFailed;

  int get pendingCount => pending.length;
  bool get hasPending => pending.isNotEmpty;

  bool isPending(String applianceId) =>
      pending.any((op) => op.applianceId == applianceId);
}

/// 가전 동기화 — **이 폰이 한 변경만**, **한 순서로**, **성공할 때까지**.
///
/// 세 가지를 지킨다.
///
/// - **영속**: 변경은 보내기 전에 기기에 먼저 적어 둔다. 서버가 꺼져 있을 때
///   등록한 가전이 스낵바 한 번으로 사라지지 않는다.
/// - **순서**: 같은 가전의 `upsert → delete`가 뒤집히면 지운 가전이 되살아나고,
///   `delete → upsert`가 뒤집히면 방금 만든 가전이 사라진다. FIFO로 보낸다.
/// - **삭제는 내 것만**: 서버에만 있는 가전은 지우지 않고 내려받아 병합한다.
///   서버 목록에만 있다는 것은 "지워도 된다"가 아니라 "이 폰이 아직 못
///   받았다"는 뜻이다.
class ApplianceSyncNotifier extends StateNotifier<ApplianceSyncState> {
  ApplianceSyncNotifier(this._ref) : super(const ApplianceSyncState()) {
    _loaded = _load();
  }

  final Ref _ref;
  late final Future<void> _loaded;
  Future<ApplianceSyncResult>? _inFlight;
  var _seq = 0;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyDeletes(prefs);
      final raw = prefs.getStringList(_kOutboxKey) ?? const [];
      final ops = [
        for (final line in raw)
          if (SyncOperation.fromJson(
                jsonDecode(line) as Map<String, dynamic>,
              )
              case final op?)
            op,
      ];
      if (!mounted) return;
      state = ApplianceSyncState(pending: ops, lastFailed: state.lastFailed);
    } catch (_) {
      // 대기열을 못 읽어도 새 변경은 받을 수 있어야 한다.
    }
  }

  /// 예전 버전은 삭제 대기를 **id 집합**으로만 남겼다
  /// (`pending_appliance_deletes`).
  ///
  /// 새 대기열만 읽으면 업데이트하는 순간 아직 못 보낸 삭제가 조용히
  /// 사라진다 -- 서버에는 유령 가전이 남고 아무도 모른다.
  ///
  /// 새 대기열에 **저장이 끝난 뒤에만** 옛 키를 지운다. 순서를 뒤집으면
  /// 저장에 실패했을 때 양쪽 다 잃는다. 옮겨온 작업에는 판 번호가 없다 --
  /// 그때는 밝히지 않고 보내 종전 동작을 유지한다.
  Future<void> _migrateLegacyDeletes(SharedPreferences prefs) async {
    const legacyKey = 'pending_appliance_deletes';
    final legacy = prefs.getStringList(legacyKey);
    if (legacy == null) return;
    final existing = prefs.getStringList(_kOutboxKey) ?? const [];
    final known = {
      for (final line in existing)
        (jsonDecode(line) as Map<String, dynamic>)['appliance_id'] as String?,
    };
    final migrated = [
      for (final id in legacy)
        if (!known.contains(id))
          SyncOperation(
            opId: 'legacy-$id',
            applianceId: id,
            kind: SyncOpKind.delete,
            createdAt: DateTime.now(),
          ),
    ];
    await prefs.setStringList(
      _kOutboxKey,
      [...existing, for (final op in migrated) jsonEncode(op.toJson())],
    );
    await prefs.remove(legacyKey);
  }

  Future<void> _persist(List<SyncOperation> ops) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kOutboxKey,
        [for (final op in ops) jsonEncode(op.toJson())],
      );
    } catch (_) {}
  }

  Future<void> _enqueue(SyncOperation op) async {
    await _loaded; // 저장된 대기열 위에 얹어야 한다 — 덮어쓰면 잃는다
    final next = [...state.pending, op];
    state = ApplianceSyncState(pending: next, lastFailed: state.lastFailed);
    await _persist(next);
  }

  String _nextOpId() => 'op-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// 가전을 저장한다(등록·수정). 로컬 저장은 무조건 성립하고, 서버 전달은
  /// 대기열을 통해 **끝까지** 시도된다.
  Future<ApplianceSyncResult> saveAppliance(ApplianceMap appliance) async {
    // 서버 내장 가전은 이 폰의 것이 아니다. 저장하지도, 올려 보내지도
    // 않는다 -- 대기열에 들어가면 서버 정의를 서버에 되돌려 보내게 된다.
    if (!appliance.isCustom) return const ApplianceSyncResult();
    final customs = _ref.read(customAppliancesProvider);
    final notifier = _ref.read(customAppliancesProvider.notifier);
    if (customs.any((a) => a.id == appliance.id)) {
      await notifier.replace(appliance);
    } else {
      await notifier.add(appliance);
    }
    await _enqueue(
      SyncOperation(
        opId: _nextOpId(),
        applianceId: appliance.id,
        kind: SyncOpKind.upsert,
        createdAt: DateTime.now(),
        payload: appliance.toJson(),
      ),
    );
    return sync();
  }

  /// 사용자가 이 폰에서 가전을 지웠다.
  ///
  /// 폰 삭제는 무조건 성립한다(사용자가 지시한 일이다). 서버 전달이
  /// 실패하면 대기열에 남아 다음 동기화가 다시 보낸다.
  Future<ApplianceSyncResult> deleteAppliance(
    String applianceId, {
    int? expectedRevision,
  }) async {
    // 서버 내장 가전은 지울 수 없다 -- DELETE를 보내면 서버 정의를 지우려
    // 드는 셈이다. 이 폰의 목록에도 없으므로 할 일이 없다.
    final isServerBuiltin = _ref
        .read(serverApplianceCatalogProvider)
        .appliances
        .any((a) => a.id == applianceId);
    if (isServerBuiltin) return const ApplianceSyncResult();
    final known = _ref
        .read(customAppliancesProvider)
        .where((a) => a.id == applianceId)
        .firstOrNull;
    await _ref.read(customAppliancesProvider.notifier).remove(applianceId);
    // 서버 목록의 보여 주기용 사본에서도 뺀다 -- 다음 조회 전까지 홈에
    // 지운 가전이 남지 않게.
    _ref.read(serverApplianceCatalogProvider.notifier).forgetCustom(applianceId);
    await _enqueue(
      SyncOperation(
        opId: _nextOpId(),
        applianceId: applianceId,
        kind: SyncOpKind.delete,
        createdAt: DateTime.now(),
        // 삭제 직전에 본 판을 함께 싣는다 -- 없으면 오래된 삭제가 남의
        // 수정을 무조건 지운다.
        revision: expectedRevision ?? known?.revision ?? 0,
      ),
    );
    return sync();
  }

  /// 이 폰의 가전 전부를 서버에 다시 올린다 — **복구용 진입점**.
  ///
  /// 대기열은 "이 폰이 한 변경"만 담는다. 그런데 서버가 꺼져 있던 시절에
  /// 등록했거나, 대기열이 생기기 전 버전에서 만든 가전은 대기열에 없다.
  /// 그런 가전이 키오스크에 영영 안 뜨는 것을 사용자가 스스로 고칠 수 있는
  /// 유일한 수단이 이 버튼이다.
  ///
  /// 이미 대기 중인 가전은 다시 넣지 않는다 — 같은 변경을 두 번 보내게 된다.
  Future<ApplianceSyncResult> resendAll() async {
    await _loaded;
    final locals = _ref.read(customAppliancesProvider);
    final queued = {for (final op in state.pending) op.applianceId};
    for (final appliance in locals) {
      if (queued.contains(appliance.id)) continue;
      await _enqueue(
        SyncOperation(
          opId: _nextOpId(),
          applianceId: appliance.id,
          kind: SyncOpKind.upsert,
          createdAt: DateTime.now(),
          payload: appliance.toJson(),
        ),
      );
    }
    return sync();
  }

  /// 대기열을 순서대로 흘려보내고, 서버 목록을 내려받아 병합한다.
  ///
  /// 겹쳐 부르면 **진행 중인 것을 기다린다**(single-flight). 그냥 또 돌리면
  /// 같은 작업이 두 번 나가고, 그 사이 순서가 뒤집힐 수 있다.
  Future<ApplianceSyncResult> sync() {
    final running = _inFlight;
    if (running != null) return running;
    final started = _sync();
    _inFlight = started;
    return started.whenComplete(() {
      if (identical(_inFlight, started)) _inFlight = null;
    });
  }

  Future<ApplianceSyncResult> _sync() async {
    // 대기열이 기기에서 올라오기 전에 진행하면 "보낼 게 없다"고 판단하고
    // 저장분을 덮어쓴다. 서버 주소도 같은 이유로 기다린다 -- 앱을 열자마자
    // 누르면 아직 null이라 "주소를 설정해 주세요"가 뜬다(설정돼 있는데도).
    await _loaded;
    await _ref.read(rpiUrlProvider.notifier).ensureLoaded();

    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) {
      state = ApplianceSyncState(pending: state.pending, lastFailed: true);
      return ApplianceSyncResult(
        failed: state.pendingCount,
        serverUnreachable: true,
      );
    }

    var sent = 0;
    var conflicts = 0;
    final remaining = <SyncOperation>[];
    // 이번 패스에서 더 손대면 안 되는 가전. 충돌한 가전이 여기 들어간다 --
    // 내 수정이 거절됐다는 것은 **서버에 내가 못 본 내용이 있다**는 뜻이고,
    // 그 상태에서 뒤의 삭제를 보내면 그걸 그대로 지워버린다.
    final blocked = <String>{};
    for (final op in state.pending) {
      // 앞의 작업이 실패했거나 충돌했으면 뒤의 것도 보내지 않는다 -- 보내면
      // 같은 가전의 순서가 뒤집히거나(지운 가전이 되살아나는 자리) 못 본
      // 내용을 지운다.
      if (blocked.contains(op.applianceId) ||
          remaining.any((r) => r.applianceId == op.applianceId)) {
        remaining.add(op);
        continue;
      }
      final outcome = await _send(api, op);
      switch (outcome) {
        case _SendOutcome.ok:
          sent++;
        case _SendOutcome.conflict:
          // 다른 기기가 먼저 바꿨다. 자동으로 덮어쓰지도, 조용히 버리지도
          // 않는다 -- 대기 상태로 남겨 사용자가 확인하게 한다. 밀린 작업을
          // 자동으로 걷어내면(재기준화·삭제) 사용자가 모르는 사이에 의도가
          // 바뀌고, 순서 보장도 함께 무너진다.
          conflicts++;
          blocked.add(op.applianceId);
          remaining.add(op);
        case _SendOutcome.failed:
          remaining.add(op);
      }
    }
    if (remaining.length != state.pending.length) {
      await _persist(remaining);
    }
    state = ApplianceSyncState(
      pending: remaining,
      lastFailed: remaining.isNotEmpty,
    );

    final merged = await _mergeFromServer(api, remaining, blocked);
    return ApplianceSyncResult(
      sent: sent,
      failed: remaining.length,
      conflicts: conflicts,
      adopted: merged ?? 0,
      serverUnreachable: merged == null,
    );
  }

  Future<_SendOutcome> _send(RpiApiService api, SyncOperation op) async {
    if (op.kind == SyncOpKind.delete) {
      // 이미 없으면 되돌려 놓으려던 상태가 이미 성립했다 -- 실패로 치면
      // 대기열에서 영영 안 빠진다. (api가 404를 성공으로 돌려준다.)
      try {
        final ok = await api.deleteAppliance(
          op.applianceId,
          expectedRevision:
              op.expectedRevision > 0 ? op.expectedRevision : null,
        );
        return ok ? _SendOutcome.ok : _SendOutcome.failed;
      } on RpiApiException catch (error) {
        return error.statusCode == 409
            ? _SendOutcome.conflict
            : _SendOutcome.failed;
      } catch (_) {
        return _SendOutcome.failed;
      }
    }
    final appliance = op.appliance;
    if (appliance == null) return _SendOutcome.ok; // 보낼 내용이 없다 -- 버린다
    try {
      final ok = await api.registerAppliance(appliance);
      return ok ? _SendOutcome.ok : _SendOutcome.failed;
    } on RpiApiException catch (error) {
      return error.statusCode == 409
          ? _SendOutcome.conflict
          : _SendOutcome.failed;
    } catch (_) {
      return _SendOutcome.failed;
    }
  }

  /// 서버에만 있는 가전을 이 폰에 더한다. 조회 실패는 null(빈 목록과 구분).
  ///
  /// **지우지 않는다.** 서버 목록에만 있다는 것은 "지워도 된다"가 아니라
  /// "이 폰이 아직 못 받았다"는 뜻이다. 로컬 사진 경로는 이 폰의 데이터라
  /// 서버 내용으로 덮지 않는다.
  Future<int?> _mergeFromServer(
    RpiApiService api,
    List<SyncOperation> stillPending,
    Set<String> conflicted,
  ) async {
    final remote = await api.customAppliances();
    if (remote == null) return null;
    final notifier = _ref.read(customAppliancesProvider.notifier);
    final locals = _ref.read(customAppliancesProvider);
    final localById = {for (final a in locals) a.id: a};
    // 아직 못 지운 가전은 도로 받아오지 않는다 -- 지운 것이 동기화 때마다
    // 되살아나면 지운 것이 아니다.
    final pendingDeletes = {
      for (final op in stillPending)
        if (op.kind == SyncOpKind.delete) op.applianceId,
    };

    var adopted = 0;
    for (final incoming in remote) {
      // `customAppliances()`가 이미 is_custom으로 거르지만, 서버 내장 가전이
      // 여기로 새어 들어오면 기기에 저장되고 다음 동기화가 올려 보낸다.
      // 마지막 문에서 한 번 더 막는다.
      if (!incoming.isCustom) continue;
      if (pendingDeletes.contains(incoming.id)) continue;
      final mine = localById[incoming.id];
      if (mine == null) {
        await notifier.add(incoming);
        adopted++;
        continue;
      }
      // 아직 보내지 못한 내 변경이 있으면 서버 내용으로 덮지 않는다.
      //
      // **충돌한 가전은 예외다.** 내 수정이 거절됐다는 것은 서버에 내가 못
      // 본 내용이 있다는 뜻이고, 그걸 보여주는 것이 "서버 내용을 가져왔어요"
      // 의 실체다. 못 보낸 변경은 대기열에 그대로 남아 있고, 화면이 그
      // 사실을 따로 알린다 — 둘 다 사실이므로 둘 다 보여준다.
      if (!conflicted.contains(incoming.id) &&
          stillPending.any((op) => op.applianceId == incoming.id)) {
        continue;
      }
      if (_sameDefinition(mine, incoming)) continue;
      // 사진은 이 폰에만 있는 데이터다 -- 서버는 모른다.
      await notifier.replace(incoming.withPhotoFrom(mine));
    }
    return adopted;
  }

  bool _sameDefinition(ApplianceMap a, ApplianceMap b) =>
      a.name == b.name &&
      a.rows == b.rows &&
      a.cols == b.cols &&
      jsonEncode(a.buttons.map((x) => x.toJson()).toList()) ==
          jsonEncode(b.buttons.map((x) => x.toJson()).toList());
}

enum _SendOutcome { ok, conflict, failed }

final applianceSyncProvider =
    StateNotifierProvider<ApplianceSyncNotifier, ApplianceSyncState>(
  ApplianceSyncNotifier.new,
);

/// 동기화할 것이 남아 있는가 — 버튼·안내를 보일지 정하는 조건.
///
/// 커스텀 가전 존재만으로 판단하면, **마지막 가전을 지우다 실패했을 때**
/// 버튼이 함께 사라져 복구할 길이 없어진다.
///
/// 평가 12차(10/18): 예전에는 사용자 가전이 하나라도 있으면 늘 떠 있어, 바꾼 것이 없는데도 '다시 보내라'는 단추가
/// 보였다. 이제는 **보낼 것이 있을 때만** — 대기열에 남은 변경(지우다 실패한 것 포함)이 있거나, 본체 목록을 받아
/// 보니 이 폰의 사용자 가전이 본체에 없을 때(본체가 꺼져 있던 때 등록해 대기열에 없던 것 — 이 단추가 복구 수단).
/// 본체 목록을 아직 못 받았으면(조회 중·실패) 없다고 단정하지 않는다 — 대기열만 본다.
final hasPendingSyncProvider = Provider<bool>((ref) {
  if (ref.watch(applianceSyncProvider).hasPending) return true;
  final catalog = ref.watch(serverApplianceCatalogProvider);
  if (!catalog.isLoaded) return false;
  final onHub = {
    for (final a in catalog.customAppliances) a.id,
    for (final a in catalog.appliances) a.id,
  };
  return ref
      .watch(customAppliancesProvider)
      .any((a) => a.isCustom && !a.isDemo && !onHub.contains(a.id));
});
