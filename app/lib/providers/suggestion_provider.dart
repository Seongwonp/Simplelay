import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/suggestion.dart';
import 'ble_provider.dart';

class SuggestionNotifier extends StateNotifier<List<Suggestion>> {
  SuggestionNotifier(this.ref) : super(const []) {
    _subscription = ref.read(bleServiceProvider).messages.listen(_onMessage);
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  void _onMessage(Map<String, dynamic> message) {
    if (message['type'] == 'suggestion') add(Suggestion.fromJson(message));
  }

  void add(Suggestion suggestion) {
    state = [
      ...state.where((item) => item.sequenceId != suggestion.sequenceId),
      suggestion,
    ];
  }

  Future<void> respond(Suggestion suggestion, bool approved) async {
    await ref
        .read(bleServiceProvider)
        .sendConfirmation(suggestion.sequenceId, approved);
    state = state
        .where((item) => item.sequenceId != suggestion.sequenceId)
        .toList();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final suggestionProvider =
    StateNotifierProvider<SuggestionNotifier, List<Suggestion>>(
  SuggestionNotifier.new,
);
