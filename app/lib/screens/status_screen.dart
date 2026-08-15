import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../providers/execution_status_provider.dart';

class StatusScreen extends ConsumerWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(executionStatusProvider);
    final active = status.phase == ExecutionPhase.running ||
        status.phase == ExecutionPhase.retrying ||
        status.phase == ExecutionPhase.waiting;
    return Scaffold(
      appBar: AppBar(title: const Text('실행 상태')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            status.label ?? '실행 중인 작업 없음',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            status.message ?? '승인한 동작의 진행 상황이 여기에 표시됩니다.',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 24),
          if (status.phase == ExecutionPhase.retrying)
            const Card(
              color: Color(0xFF5A4214),
              child: ListTile(
                leading: Icon(Icons.refresh),
                title: Text('버튼 동작 재시도 중'),
              ),
            ),
          ...List.generate(status.steps.length, (index) {
            final done = index < status.completedSteps;
            final current = index == status.completedSteps && active;
            return ListTile(
              leading: Icon(
                done
                    ? Icons.check_circle
                    : current
                        ? Icons.pending
                        : Icons.radio_button_unchecked,
                color: done || current
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white38,
              ),
              title: Text(readableStep(status.steps[index])),
              subtitle: Text(status.steps[index]),
            );
          }),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _SensorCard(
                  icon: Icons.electric_bolt,
                  label: '전류',
                  value: status.currentMa == null
                      ? '--'
                      : '${status.currentMa!.toStringAsFixed(0)} mA',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SensorCard(
                  icon: Icons.graphic_eq,
                  label: '음향',
                  value: status.soundDb == null
                      ? '--'
                      : '${status.soundDb!.toStringAsFixed(0)} dB',
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          if (active)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () =>
                  ref.read(executionStatusProvider.notifier).emergencyStop(),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('긴급 정지'),
            ),
        ],
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  const _SensorCard({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(color: Colors.white60)),
              Text(value, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      );
}
