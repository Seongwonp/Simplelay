import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';

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
  CustomAppliancesNotifier.seeded(List<ApplianceMap> appliances)
      : super(appliances) {
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
    state = [...state, appliance];
    await _save();
  }

  /// 같은 id의 정의를 갈아 끼운다(목록 순서 유지).
  Future<void> replace(ApplianceMap appliance) async {
    state = [
      for (final a in state) if (a.id == appliance.id) appliance else a,
    ];
    await _save();
  }

  Future<void> remove(String id) async {
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

/// **사용자가 실제로 등록한** 가전만.
///
/// 템플릿을 여기 섞지 않는다. 한 대도 등록하지 않았으면 비어 있고, 화면은
/// 그 사실을 그대로 보여줘야 한다 -- 있지도 않은 전자레인지를 가진 것처럼
/// 말하지 않는다.
final installedAppliancesProvider = Provider<List<ApplianceMap>>((ref) {
  return ref.watch(customAppliancesProvider);
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
    _loadFuture = Future<void>.value();
    _watchInstalled();
  }

  final Ref _ref;
  late final Future<void> _loadFuture;
  bool _loaded = false;

  /// 저장된 선택을 다 읽었는가. 시작 화면이 이걸 기다린다.
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _load() async {
    // 설치 목록이 먼저 올라와야 저장된 선택이 그 안에 있는지 볼 수 있다.
    await _ref.read(customAppliancesProvider.notifier).ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('selected_appliance');
    final installed = _ref.read(installedAppliancesProvider);
    _loaded = true;
    if (!mounted) return;
    // 저장된 선택이 설치 목록에 있으면 그것, 없으면(지웠거나 한 번도 고른
    // 적이 없다) **내가 가진 것 중 첫 번째**. 어느 쪽이든 실제로 등록한
    // 가전만 고른다 -- 가진 적 없는 전자레인지를 세우지는 않는다.
    state = installed.where((a) => a.id == id).firstOrNull ??
        installed.firstOrNull;
    if (state?.id != id) unawaited(_persist(state?.id));
  }

  /// 설치 목록이 바뀌면 선택도 같이 맞춘다.
  ///
  /// 이게 없으면 방금 지운 가전을 화면이 계속 가리키고, 첫 가전을 추가해도
  /// 홈은 여전히 '등록한 가전이 없어요'라고 말한다.
  void _watchInstalled() {
    _ref.listen<List<ApplianceMap>>(customAppliancesProvider, (_, installed) {
      // 복원이 끝나기 전에 끼어들면 저장된 선택을 첫 번째로 덮어쓴다.
      if (!_loaded) return;
      final current = state;
      final next = current == null
          ? installed.firstOrNull
          // 편집된 정의를 다시 집는다. 못 찾으면(삭제) 남은 것 중 첫 번째.
          : installed.where((a) => a.id == current.id).firstOrNull ??
              installed.firstOrNull;
      if (identical(next, current)) return;
      state = next;
      if (next?.id != current?.id) unawaited(_persist(next?.id));
    });
  }

  Future<void> select(ApplianceMap appliance) async {
    state = appliance;
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
