import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/appliance.dart';

class SelectedApplianceNotifier extends StateNotifier<ApplianceMap> {
  SelectedApplianceNotifier() : super(kAppliances.first) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('selected_appliance') ?? kAppliances.first.id;
    state = applianceById(id);
  }

  Future<void> select(ApplianceMap appliance) async {
    state = appliance;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_appliance', appliance.id);
  }
}

final selectedApplianceProvider =
    StateNotifierProvider<SelectedApplianceNotifier, ApplianceMap>(
  (ref) => SelectedApplianceNotifier(),
);
