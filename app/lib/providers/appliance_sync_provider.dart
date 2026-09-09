import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';
import '../services/rpi_api_service.dart';
import 'appliance_provider.dart';
import 'rpi_api_provider.dart';

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
  });

  final String opId;
  final String applianceId;
  final SyncOpKind kind;
  final DateTime createdAt;

  /// upsert일 때 보낼 가전 정의 스냅샷. delete는 null.
  final Map<String, dynamic>? payload;

  ApplianceMap? get appliance =>
      payload == null ? null : ApplianceMap.fromJson(payload!);

  Map<String, dynamic> toJson() => {
        'op_id': opId,
        'appliance_id': applianceId,
        'kind': kind.name,
        'created_at': createdAt.toIso8601String(),
        if (payload != null) 'payload': payload,
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
  Future<ApplianceSyncResult> deleteAppliance(String applianceId) async {
    await _ref.read(customAppliancesProvider.notifier).remove(applianceId);
    await _enqueue(
      SyncOperation(
        opId: _nextOpId(),
        applianceId: applianceId,
        kind: SyncOpKind.delete,
        createdAt: DateTime.now(),
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
    for (final op in state.pending) {
      // 앞의 작업이 실패했으면 뒤의 것도 보내지 않는다 -- 보내면 같은
      // 가전의 순서가 뒤집힌다(지운 가전이 되살아나는 자리).
      if (remaining.any((r) => r.applianceId == op.applianceId)) {
        remaining.add(op);
        continue;
      }
      final outcome = await _send(api, op);
      switch (outcome) {
        case _SendOutcome.ok:
          sent++;
        case _SendOutcome.conflict:
          // 다른 기기가 먼저 바꿨다. 자동으로 덮어쓰지 않는다 -- 대기열에서
          // 빼고, 아래 병합이 서버 내용을 가져온다.
          conflicts++;
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

    final merged = await _mergeFromServer(api, remaining);
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
      return await api.deleteAppliance(op.applianceId)
          ? _SendOutcome.ok
          : _SendOutcome.failed;
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
      if (pendingDeletes.contains(incoming.id)) continue;
      final mine = localById[incoming.id];
      if (mine == null) {
        await notifier.add(incoming);
        adopted++;
        continue;
      }
      // 아직 보내지 못한 내 변경이 있으면 서버 내용으로 덮지 않는다.
      if (stillPending.any((op) => op.applianceId == incoming.id)) continue;
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
final hasPendingSyncProvider = Provider<bool>((ref) {
  final hasCustom = ref.watch(customAppliancesProvider).isNotEmpty;
  return hasCustom || ref.watch(applianceSyncProvider).hasPending;
});
