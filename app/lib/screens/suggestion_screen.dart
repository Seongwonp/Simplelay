import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/suggestion.dart';
import '../providers/execution_status_provider.dart';
import '../providers/suggestion_provider.dart';

class SuggestionScreen extends ConsumerWidget {
  const SuggestionScreen({required this.sequenceId, super.key});

  final String sequenceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(suggestionProvider);
    final suggestion =
        items.where((item) => item.sequenceId == sequenceId).firstOrNull;
    if (suggestion == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('제안 확인')),
        body: const Center(child: Text('제안을 찾을 수 없습니다.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('제안 확인')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.auto_awesome, size: 44),
          const SizedBox(height: 12),
          Text(
            suggestion.label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '아래 순서대로 버튼을 누를까요?',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 32),
          ...List.generate(suggestion.steps.length, (index) {
            final code = suggestion.steps[index];
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    CircleAvatar(child: Text('${index + 1}')),
                    if (index < suggestion.steps.length - 1)
                      Container(width: 2, height: 52, color: Colors.white24),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 14),
                    child: ListTile(
                      leading: const Icon(Icons.touch_app),
                      title: Text(readableStep(code)),
                      subtitle: Text(code),
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, false);
                    if (context.mounted) context.pop();
                  },
                  child: const Text('거부'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () async {
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, true);
                    ref
                        .read(executionStatusProvider.notifier)
                        .begin(suggestion);
                    if (context.mounted) context.go('/status');
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('승인하고 실행'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
