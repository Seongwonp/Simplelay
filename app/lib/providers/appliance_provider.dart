import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';
import 'demo_provider.dart';
import 'server_appliance_provider.dart';

// ── 사용자 정의 가전 (기기 추가) ────────────────────────────────────────────

class CustomAppliancesNotifier extends StateNotifier<List<ApplianceMap>> {
  CustomAppliancesNotifier() : super(const []) {
    _loadFuture = _load();
  }

  /// 저장소를 거치지 않고 목록을 세운다. **테스트 전용.**
  ///
  /// 화면 테스트가 기기 저장소를 기다리면 첫 프레임이 항상 '가전 없음'이라,
  /// 정작 확인하려던 화면을 못 본다.
  @visibleForTesting
  CustomAppliancesNotifier.seeded(super.state) {
    _loadFuture = Future<void>.value();
  }

  static const _prefsKey = 'custom_appliances';
  late final Future<void> _loadFuture;

  // 다른 provider(예: selectedApplianceProvider)가 저장된 선택값을 커스텀
  // 가전 목록과 대조해야 할 때, 로딩 레이스 없이 기다릴 수 있게 노출한다.
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    state = raw
        .map((s) => ApplianceMap.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> add(ApplianceMap appliance) async {
    // 서버 내장 가전은 이 폰의 등록 목록이 아니다. 여기 들어오면 기기에
    // 저장되고 다음 동기화가 PUT으로 올려 보낸다 -- 서버 것을 서버에
    // 되돌려 보내는 셈이다. 어떤 경로로 오든 여기서 막는다.
    if (!appliance.isCustom) return;
    // 읽기가 끝나기 전에 고치면, 뒤늦게 끝난 `_load()`가 이 변경을 덮어쓴다.
    // 앱을 켜자마자 가전을 추가한 사람은 방금 등록한 것이 사라지는 걸 본다.
    await _loadFuture;
    state = [...state, appliance];
    await _save();
  }

  /// 같은 id의 정의를 갈아 끼운다(목록 순서 유지).
  Future<void> replace(ApplianceMap appliance) async {
    if (!appliance.isCustom) return;
    await _loadFuture;
    state = [
      for (final a in state) if (a.id == appliance.id) appliance else a,
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    await _loadFuture;
    final removed = state.where((a) => a.id == id).firstOrNull;
    state = state.where((a) => a.id != id).toList();
    await _save();
    // 등록 사진 파일도 함께 정리 — 실패해도 목록 삭제는 이미 끝났으므로 무시
    final photoPath = removed?.photoPath;
    if (photoPath != null) {
      try {
        await File(photoPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      state.map((a) => jsonEncode(a.toJson())).toList(),
    );
  }
}

final customAppliancesProvider =
    StateNotifierProvider<CustomAppliancesNotifier, List<ApplianceMap>>(
  (ref) => CustomAppliancesNotifier(),
);

/// 지금 이 폰에서 **고를 수 있는** 가전 -- 두 출처를 합친다.
///
/// 1. **서버 내장 가전**(`serverApplianceCatalogProvider`). 서버가 지금
///    제공하는 것이라 기기에 저장하지 않고, 서버가 바뀌면 함께 사라진다.
///    편집·삭제·PUT/DELETE 동기화 대상이 아니다.
/// 2. **사용자가 등록한 가전**(`customAppliancesProvider`). 이 폰의 것이고
///    동기화 대기열을 거쳐 서버에도 올라간다.
///
/// 템플릿을 여기 섞지 않는다. 둘 다 비어 있으면 목록도 비고, 화면은 그
/// 사실을 그대로 보여줘야 한다 -- 있지도 않은 전자레인지를 가진 것처럼
/// 말하지 않는다. 서버 조회가 **실패**한 것과 서버에 **정말 없는** 것은
/// 목록만으로는 같아 보이므로, 그 구분은 서버 목록의 상태를 따로 본다.
///
/// 예외는 **명시적으로 켠 데모 세션**뿐이다(`kDebugMode`가 아니라 설정에서
/// 켠 값). 서버 가전도 등록 가전도 없을 때만 표본을 세운다 -- 리허설에서
/// 빈 화면만 보이면 보여줄 것이 없고, 그렇다고 표본을 항상 세우면 실제
/// 사용자의 첫 화면을 아무도 못 본다. 표본은 `isDemo`로 표시되고 기기에
/// 저장되지 않는다.
final installedAppliancesProvider = Provider<List<ApplianceMap>>((ref) {
  final own = ref.watch(customAppliancesProvider);
  final server = ref.watch(serverApplianceCatalogProvider).appliances;
  // 같은 id가 양쪽에 있으면 사용자 것이 남는다 -- 사용자 데이터를 서버
  // 항목으로 가리지 않는다. 정상 경로에서는 생기지 않는 충돌이다(등록
  // id는 시각으로 만든다).
  final ownIds = {for (final a in own) a.id};
  final combined = [
    for (final a in server)
      if (!ownIds.contains(a.id)) a,
    ...own,
  ];
  if (combined.isNotEmpty) return combined;
  return ref.watch(demoModeProvider) ? kDemoAppliances : const [];
});

/// 시작에 필요한 것이 **다 올라왔는가**.
///
/// 시작 화면이 이 신호를 기다린 뒤 한 번만 라우팅한다. 임의의 지연으로
/// 맞추면 느린 기기에서 홈이 잠깐 보였다가 바뀌는 깜빡임이 생기고,
/// 테스트도 흔들린다.
final applianceStartupProvider = FutureProvider<void>((ref) async {
  await ref.read(customAppliancesProvider.notifier).ensureLoaded();
  await ref.read(selectedApplianceProvider.notifier).ensureLoaded();
});

// ── 선택된 가전 ──────────────────────────────────────────────────────────

/// 지금 조작할 가전. **없을 수 있다.**
///
/// 예전에는 선택값이 없거나 가리키던 가전이 지워졌을 때 전자레인지로
/// 되돌렸다. 그러면 사용자는 자기가 지운 가전 대신 가진 적도 없는 가전을
/// 보게 되고, 그 사실을 알 방법이 없다. 고를 것이 없으면 없는 것이다.
class SelectedApplianceNotifier extends StateNotifier<ApplianceMap?> {
  SelectedApplianceNotifier(this._ref) : super(null) {
    _loadFuture = _load();
    _watchInstalled();
  }

  /// 저장소를 거치지 않고 선택을 세운다. **테스트 전용.**
  @visibleForTesting
  SelectedApplianceNotifier.seeded(this._ref, ApplianceMap? appliance)
      : super(appliance) {
    _loaded = true;
    _preferredId = appliance?.id;
    _loadFuture = Future<void>.value();
    _watchInstalled();
  }

  final Ref _ref;
  late final Future<void> _loadFuture;
  bool _loaded = false;

  /// 사용자가 **직접 고른**(또는 저장돼 있던) 가전의 id.
  ///
  /// 지금 화면의 선택과 다를 수 있다. 서버 목록이 늦게 올라오거나 서버가
  /// 바뀌는 동안 선택은 남은 것 중 첫 번째로 잠시 내려가는데, 그때 이 값을
  /// 덮어쓰면 서버가 돌아와도 원래 고르던 가전으로 돌아가지 못한다.
  String? _preferredId;

  /// 저장된 선택을 다 읽었는가. 시작 화면이 이걸 기다린다.
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _load() async {
    // 설치 목록이 먼저 올라와야 저장된 선택이 그 안에 있는지 볼 수 있다.
    // 서버 목록은 기다리지 않는다 -- 네트워크가 시작 화면을 붙잡으면 안
    // 되고, 올라오면 `_watchInstalled`가 저장된 선택을 다시 대조한다.
    await _ref.read(customAppliancesProvider.notifier).ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('selected_appliance');
    final installed = _ref.read(installedAppliancesProvider);
    _preferredId = id;
    _loaded = true;
    if (!mounted) return;
    // 저장된 선택이 설치 목록에 있으면 그것, 없으면(지웠거나 한 번도 고른
    // 적이 없다) **지금 고를 수 있는 것 중 첫 번째**. 어느 쪽이든 실제로
    // 있는 가전만 고른다 -- 가진 적 없는 전자레인지를 세우지는 않는다.
    state = _pick(installed, current: null);
  }

  /// 목록 안에서 무엇을 가리킬지 정한다. 우선순위:
  /// 사용자가 고른 id → 지금 가리키던 id(정의만 바뀐 경우) → 첫 번째 → 없음.
  ApplianceMap? _pick(List<ApplianceMap> installed, {ApplianceMap? current}) {
    ApplianceMap? byId(String? id) =>
        id == null ? null : installed.where((a) => a.id == id).firstOrNull;
    return byId(_preferredId) ?? byId(current?.id) ?? installed.firstOrNull;
  }

  /// 고를 수 있는 목록이 바뀌면 선택도 같이 맞춘다.
  ///
  /// 이게 없으면 방금 지운 가전을 화면이 계속 가리키고, 첫 가전을 추가해도
  /// 홈은 여전히 '등록한 가전이 없어요'라고 말한다. 서버가 바뀌어 내장
  /// 가전이 사라지면 그 선택도 함께 내려간다 -- 이전 서버의 가전을 새
  /// 서버에서 조작하는 화면을 두지 않는다.
  void _watchInstalled() {
    _ref.listen<List<ApplianceMap>>(installedAppliancesProvider, (_, installed) {
      // 복원이 끝나기 전에 끼어들면 저장된 선택을 첫 번째로 덮어쓴다.
      if (!_loaded) return;
      final current = state;
      final next = _pick(installed, current: current);
      if (!identical(next, current)) state = next;
      // 자동으로 옮긴 선택은 저장하지 않는다. 저장된 값은 사용자가 고른
      // 것이어야 목록이 돌아왔을 때 그리로 되돌아갈 수 있다.
      //
      // 고른 가전이 목록에 없다고 바로 잊지도 않는다. 서버 목록이 **조회
      // 중**이거나 **조회에 실패**한 동안은 비어 있는 것이 일시적이다 -- 같은
      // 서버를 다시 받으면 고른 가전이 돌아온다. 지우는 것은 서버 목록이
      // **확정된**(loaded) 상태에서도 없을 때뿐이다: 삭제됐거나, 새 서버에
      // 그 가전이 없거나, 정말 빈 목록이다.
      final preferred = _preferredId;
      if (preferred != null &&
          _ref.read(serverApplianceCatalogProvider).isLoaded &&
          !installed.any((a) => a.id == preferred)) {
        _preferredId = null;
        unawaited(_persist(null));
      }
    });
  }

  Future<void> select(ApplianceMap appliance) async {
    state = appliance;
    _preferredId = appliance.id;
    await _persist(appliance.id);
  }

  Future<void> _persist(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('selected_appliance');
    } else {
      await prefs.setString('selected_appliance', id);
    }
  }
}

final selectedApplianceProvider =
    StateNotifierProvider<SelectedApplianceNotifier, ApplianceMap?>(
  (ref) => SelectedApplianceNotifier(ref),
);
