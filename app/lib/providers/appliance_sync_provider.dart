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

/// 마지막으로 목록을 맞춰 본 본체 주소 — 본체에서 지워진 가전을 폰에서도 뺄 때 '같은 본체인가'를 가린다.
const _kHubUrlKey = 'appliance_sync_hub_url';

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

  /// upsert일 때 보낼 가전 정의 스냅샷. delete는 지울 때 본 정의(없을 수 있다 — 옛 대기열) —
  /// 판만 어긋난 충돌인지 가를 때 쓴다([ApplianceSyncNotifier] `_rebaseRevisionOnly`).
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
    // 본체 목록을 받아 보니 이 폰이 본체와 맞췄던 가전(판 번호가 있다)이 빠져 있으면 한 번 맞춘다 — 본체에서 지운
    // 가전이 폰에 '설정이 남았어요'·'보낼 것 N건'으로 영영 남던 것(10/19). 실제로 뺄지는 [_sync]가 새로 받은 목록으로 정한다.
    _ref.listen<bool>(_hubDroppedSyncedProvider, (_, next) {
      if (next) sync();
    }, fireImmediately: true);
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

  /// 끝난 작업 하나를 **지금의** 대기열에서 뺀다 — 동기화가 처음 본 목록으로 대기열을 바꿔 쓰면, 그 사이 저장한
  /// 변경이 메모리와 기기 저장에서 함께 사라진다(검토 10/19).
  Future<void> _dequeue(String opId) async {
    final next = [
      for (final op in state.pending)
        if (op.opId != opId) op,
    ];
    if (next.length == state.pending.length) return;
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
        // 지울 때 본 정의 — 판만 어긋난 충돌을 가린다. 판 번호는 아래 revision이 말한다.
        payload: known == null ? null : ({...known.toJson()}..remove('revision')),
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

    // 보내기 전에 본체에서 이미 지워진 가전을 걷어낸다 — 안 그러면 그 가전의 고치기(PUT)가 본체 판 0과 어긋나
    // '다른 기기에서 먼저 변경'으로 매번 거절돼 대기열에서 영영 안 빠진다.
    final hubNow = await api.customAppliances();
    if (hubNow != null) await _dropGoneFromHub(api.baseUrl, hubNow);

    var sent = 0;
    var conflicts = 0;
    // 이번 패스에서 더 손대면 안 되는 가전. 충돌한 가전이 여기 들어간다 --
    // 내 수정이 거절됐다는 것은 **서버에 내가 못 본 내용이 있다**는 뜻이고,
    // 그 상태에서 뒤의 삭제를 보내면 그걸 그대로 지워버린다.
    final blocked = <String>{};
    // 앞 작업이 대기열에 남은(실패·충돌·보류) 가전.
    final heldBack = <String>{};
    // 이번 패스에서 다룬 작업. 대기열은 매번 **지금 것**을 다시 읽는다 — 보내는 사이 저장한 변경이 뒤에 붙어
    // 있으면 같은 패스에서 이어 보낸다(검토 10/19).
    final attempted = <String>{};
    while (true) {
      final op = state.pending
          .where((o) => !attempted.contains(o.opId))
          .firstOrNull;
      if (op == null) break;
      attempted.add(op.opId);
      // 앞의 작업이 실패했거나 충돌했으면 뒤의 것도 보내지 않는다 -- 보내면
      // 같은 가전의 순서가 뒤집히거나(지운 가전이 되살아나는 자리) 못 본
      // 내용을 지운다.
      if (blocked.contains(op.applianceId) ||
          heldBack.contains(op.applianceId)) {
        heldBack.add(op.applianceId);
        continue;
      }
      var (outcome, savedRevision) = await _send(api, op);
      SyncOperation? rebased;
      if (outcome == _SendOutcome.conflict) {
        // 본체 판만 올랐고 내용은 내가 본 그대로면 그 판으로 한 번 더 보낸다 — 아니면 '다시 하기'가
        // 영영 같은 옛 판을 보내 끝나지 않았다(실화면 10/19).
        rebased = await _rebaseRevisionOnly(api, op);
        if (rebased != null) (outcome, savedRevision) = await _send(api, rebased);
      }
      switch (outcome) {
        case _SendOutcome.ok:
          sent++;
          // 대기열에서 빼기 전에 본체가 돌려준 판을 받아 둔다(검토 10/19).
          if (savedRevision > 0) {
            await _adoptSavedRevision(op, rebased, savedRevision);
          }
          await _dequeue(op.opId);
        case _SendOutcome.conflict:
          // 다른 기기가 먼저 바꿨다. 자동으로 덮어쓰지도, 조용히 버리지도
          // 않는다 -- 대기 상태로 남겨 사용자가 확인하게 한다. 밀린 작업을
          // 자동으로 걷어내면(재기준화·삭제) 사용자가 모르는 사이에 의도가
          // 바뀌고, 순서 보장도 함께 무너진다.
          conflicts++;
          blocked.add(op.applianceId);
          heldBack.add(op.applianceId);
        case _SendOutcome.failed:
          heldBack.add(op.applianceId);
      }
    }
    final remaining = state.pending;
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

  /// 본체가 **본 적 있는** 가전(판 번호가 있다)이 지금 본체 목록에 없으면 본체에서 지운 것이다 — 본체가 진실원천이므로
  /// 폰에서도 빼고 그 가전의 대기 작업을 버린다(지우기는 이미 이뤄졌고, 고치기는 보낼 곳이 없다).
  ///
  /// 이 폰에서만 만들고 아직 못 보낸 가전(판 0)은 건드리지 않는다 — 그것은 '본체가 아직 못 받았다'이지 '지웠다'가 아니다.
  /// 다른 본체로 주소를 바꾼 것일 수도 있으므로, 지난번과 같은 주소이거나 이 폰이 맞춘 가전이 하나라도 이 본체에 있을
  /// 때만 뺀다 — 새 본체에 붙자마자 옛 본체의 가전을 모두 지우지 않게.
  Future<void> _dropGoneFromHub(String hubUrl, List<ApplianceMap> hub) async {
    final onHub = {for (final a in hub) a.id};
    final synced = [
      for (final a in _ref.read(customAppliancesProvider))
        if (a.isCustom && !a.isDemo && a.revision > 0) a,
    ];
    String? lastHub;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      lastHub = prefs.getString(_kHubUrlKey);
    } catch (_) {}
    final sameHub = lastHub == null ||
        lastHub == hubUrl ||
        synced.any((a) => onHub.contains(a.id));
    if (!sameHub) return;
    try {
      if (lastHub != hubUrl) await prefs?.setString(_kHubUrlKey, hubUrl);
    } catch (_) {}

    final gone = {
      for (final a in synced)
        if (!onHub.contains(a.id)) a.id,
    };
    // 본체가 본 판을 들고 있는 고치기는 본체에서 지워진 가전의 것이다. 판 없는 고치기(처음 등록)는 남긴다 — 보내면
    // 본체에 생긴다. 그 밖의 없는 가전 지우기는 그대로 보낸다 — 앞의 처음 등록이 먼저 만들 수 있고, 이미 없으면 404가 끝낸다.
    bool settledByHub(SyncOperation op) =>
        gone.contains(op.applianceId) ||
        (!onHub.contains(op.applianceId) &&
            op.kind == SyncOpKind.upsert &&
            op.expectedRevision > 0);
    for (final id in gone) {
      await _ref.read(customAppliancesProvider.notifier).remove(id);
      _ref.read(serverApplianceCatalogProvider.notifier).forgetCustom(id);
    }
    // 지금의 대기열에서 거른다 — 위에서 기다리는 사이 저장한 변경을 잃지 않게.
    final kept = [
      for (final op in state.pending)
        if (!settledByHub(op)) op,
    ];
    if (kept.length != state.pending.length) {
      state = ApplianceSyncState(pending: kept, lastFailed: state.lastFailed);
      await _persist(kept);
    }
  }

  /// 보낸 결과와, 고치기(PUT)가 성공했으면 본체가 저장한 판 번호(모르면 0).
  Future<(_SendOutcome, int)> _send(RpiApiService api, SyncOperation op) async {
    if (op.kind == SyncOpKind.delete) {
      // 이미 없으면 되돌려 놓으려던 상태가 이미 성립했다 -- 실패로 치면
      // 대기열에서 영영 안 빠진다. (api가 404를 성공으로 돌려준다.)
      try {
        final ok = await api.deleteAppliance(
          op.applianceId,
          expectedRevision:
              op.expectedRevision > 0 ? op.expectedRevision : null,
        );
        return (ok ? _SendOutcome.ok : _SendOutcome.failed, 0);
      } on RpiApiException catch (error) {
        return (
          error.statusCode == 409 ? _SendOutcome.conflict : _SendOutcome.failed,
          0,
        );
      } catch (_) {
        return (_SendOutcome.failed, 0);
      }
    }
    final appliance = op.appliance;
    if (appliance == null) return (_SendOutcome.ok, 0); // 보낼 내용이 없다 -- 버린다
    try {
      final saved = await api.registerAppliance(appliance);
      return saved == null ? (_SendOutcome.failed, 0) : (_SendOutcome.ok, saved);
    } on RpiApiException catch (error) {
      return (
        error.statusCode == 409 ? _SendOutcome.conflict : _SendOutcome.failed,
        0,
      );
    } catch (_) {
      return (_SendOutcome.failed, 0);
    }
  }

  /// 고치기가 성공해 본체가 돌려준 판 [saved]를 받아 둔다 — 이 폰의 가전과, 같은 가전의 뒤 작업 중 **보낸 것과 같은
  /// 판 위에서 만든 것**만. 내용은 건드리지 않는다: 그 사이 이 폰에서 다시 고쳤으면 그 고치기도 방금 보낸 것 위에서
  /// 한 것이라 판만 따라가면 된다. 다른 판 위의 것(본체에서 받은 더 새 내용 등)은 그대로 둔다.
  Future<void> _adoptSavedRevision(
    SyncOperation op,
    SyncOperation? rebased,
    int saved,
  ) async {
    final bases = {op.expectedRevision, if (rebased != null) rebased.expectedRevision};
    final local = _ref
        .read(customAppliancesProvider)
        .where((a) => a.id == op.applianceId)
        .firstOrNull;
    if (local != null && local.revision != saved && bases.contains(local.revision)) {
      await _ref
          .read(customAppliancesProvider.notifier)
          .replace(ApplianceMap.fromJson({...local.toJson(), 'revision': saved}));
    }
    var changed = false;
    final next = <SyncOperation>[];
    for (final o in state.pending) {
      if (o.opId == op.opId ||
          o.applianceId != op.applianceId ||
          !bases.contains(o.expectedRevision)) {
        next.add(o);
        continue;
      }
      changed = true;
      next.add(SyncOperation(
        opId: o.opId,
        applianceId: o.applianceId,
        kind: o.kind,
        createdAt: o.createdAt,
        payload: o.kind == SyncOpKind.upsert && o.payload != null
            ? {...o.payload!, 'revision': saved}
            : o.payload,
        revision: saved,
      ));
    }
    if (!changed) return;
    state = ApplianceSyncState(pending: next, lastFailed: state.lastFailed);
    await _persist(next);
  }

  /// 충돌한 작업이 **판 번호만** 어긋났는가 — 본체의 지금 정의가 이 작업이 본 정의와 같으면
  /// 본체 판으로 바꾼 작업을 돌려준다. 내용이 다르거나(정말 다른 데서 바꿨다) 비교할 정의가 없으면 null —
  /// 그때는 종전대로 사람이 정한다. 본체에서 이미 사라진 가전의 삭제는 404가 성공으로 처리하므로 여기 오지 않는다.
  Future<SyncOperation?> _rebaseRevisionOnly(RpiApiService api, SyncOperation op) async {
    final seen = op.payload;
    if (seen == null) return null;
    final List<ApplianceMap>? remote;
    try {
      remote = await api.customAppliances();
    } catch (_) {
      return null;
    }
    final server = remote?.where((a) => a.id == op.applianceId).firstOrNull;
    if (server == null || server.revision <= 0) return null;
    final mine = ApplianceMap.fromJson(seen);
    // 본체와 맞추는 정의 전부가 같아야 남의 수정이 없었다고 본다 — 놓인 곳·목적까지(검토 10/19).
    if (!_sameDefinition(server, mine)) return null;
    return SyncOperation(
      opId: op.opId,
      applianceId: op.applianceId,
      kind: op.kind,
      createdAt: op.createdAt,
      payload: {...seen, 'revision': server.revision},
      revision: server.revision,
    );
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
      // 사진을 얹은 모습으로 견준다 — 이 폰에만 있는 것은 차이가 아니다.
      if (_sameDefinition(mine, incoming.withPhotoFrom(mine))) {
        // 내용은 같아도 판 번호는 본체를 따른다. 다시 보내기(PUT)가 본체 판을 올린 뒤 옛 판을 들고 있으면
        // 다음 지우기·고치기가 '다른 기기에서 먼저 변경'으로 거절돼 폰에서만 지워지고 본체에는 남았다(실화면 10/19).
        if (incoming.revision > 0 && incoming.revision != mine.revision) {
          await notifier.replace(
              ApplianceMap.fromJson({...mine.toJson(), 'revision': incoming.revision}));
        }
        continue;
      }
      // 사진은 이 폰에만 있는 데이터다 -- 서버는 모른다.
      await notifier.replace(incoming.withPhotoFrom(mine));
    }
    return adopted;
  }

  /// 본체와 맞추는 정의가 같은가 — 이름·놓인 곳·종류·조작 경로·격자·버튼(모르는 키까지)·사진 위 자리·정지 버튼·
  /// 목적. 이 폰에만 있는 것(사진)·판 번호·살아 있는 준비 상태는 뺀다. 이름·격자·버튼만 보면 다른 기기가 바꾼
  /// 놓인 곳·목적을 '판만 다름'으로 보고 옛 내용을 새 판으로 다시 보내 덮었다(검토 10/19).
  bool _sameDefinition(ApplianceMap a, ApplianceMap b) =>
      _canonical(a) == _canonical(b);

  static String _canonical(ApplianceMap a) => jsonEncode(_sortedKeys({
        'name': a.name,
        'location': (a.location?.trim().isEmpty ?? true) ? null : a.location!.trim(),
        'category': a.category.value,
        'control_path': a.controlPath,
        'rows': a.rows,
        'cols': a.cols,
        'buttons': [for (final b in a.buttons) b.toJson()],
        'panel_mapping': a.panelMapping?.toJson(),
        'stop_button': a.stopButton,
        'functions': a.functions,
      }));

  /// 키 순서가 달라도 같은 값이면 같은 글이 되게.
  static Object? _sortedKeys(Object? value) => switch (value) {
        Map() => {
            for (final k in (value.keys.map((k) => '$k').toList()..sort()))
              k: _sortedKeys(value[k]),
          },
        List() => [for (final v in value) _sortedKeys(v)],
        _ => value,
      };
}

enum _SendOutcome { ok, conflict, failed }

/// 받아 둔 본체 목록에 이 폰이 맞췄던 가전(판 번호가 있다)이 빠져 있는가 — 동기화를 한 번 돌릴 신호일 뿐이다.
/// 받아 둔 목록은 오래됐을 수 있으므로 뺄지는 [ApplianceSyncNotifier] 동기화가 새로 받은 목록으로 정한다.
final _hubDroppedSyncedProvider = Provider<bool>((ref) {
  final catalog = ref.watch(serverApplianceCatalogProvider);
  if (!catalog.isLoaded) return false;
  final onHub = {for (final a in catalog.customAppliances) a.id};
  return ref.watch(customAppliancesProvider).any(
        (a) => a.isCustom && !a.isDemo && a.revision > 0 && !onHub.contains(a.id),
      );
});

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
