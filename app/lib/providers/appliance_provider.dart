import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';

// ── 사용자 정의 가전 (기기 추가) ────────────────────────────────────────────

class CustomAppliancesNotifier extends StateNotifier<List<ApplianceMap>> {
  CustomAppliancesNotifier() : super(const []) {
    _loadFuture = _load();
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

// 내장 가전(kAppliances) + 사용자 정의 가전을 합친 전체 목록.
final allAppliancesProvider = Provider<List<ApplianceMap>>((ref) {
  final custom = ref.watch(customAppliancesProvider);
  return [...kAppliances, ...custom];
});

// ── 선택된 가전 ──────────────────────────────────────────────────────────

class SelectedApplianceNotifier extends StateNotifier<ApplianceMap> {
  SelectedApplianceNotifier(this._ref) : super(kAppliances.first) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    // 커스텀 목록이 아직 안 불려왔으면 저장된 선택값이 커스텀 가전일 때
    // kAppliances.first로 잘못 되돌아갈 수 있어서, 먼저 로딩을 기다린다.
    await _ref.read(customAppliancesProvider.notifier).ensureLoaded();
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('selected_appliance') ?? kAppliances.first.id;
    state = _findById(id);
  }

  ApplianceMap _findById(String id) {
    final all = _ref.read(allAppliancesProvider);
    return all.where((a) => a.id == id).firstOrNull ?? kAppliances.first;
  }

  Future<void> select(ApplianceMap appliance) async {
    state = appliance;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_appliance', appliance.id);
  }
}

final selectedApplianceProvider =
    StateNotifierProvider<SelectedApplianceNotifier, ApplianceMap>(
  (ref) => SelectedApplianceNotifier(ref),
);
