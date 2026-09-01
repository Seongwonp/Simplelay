import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/care_events_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 보호자 알림함 — 실패·위험소리·긴급정지·안부 신호를 시간순으로.
///
/// 이 사건들은 그동안 키오스크(가전 옆 화면)에만 표시됐다. 정작 걱정하는
/// 보호자는 밖에 있는데 볼 방법이 없었다 — 실제 고독사 예방 서비스들이
/// "이상 신호를 담당자에게 알림"을 핵심으로 두는 이유와 같다.
class CareEventsScreen extends ConsumerStatefulWidget {
  const CareEventsScreen({super.key});

  @override
  ConsumerState<CareEventsScreen> createState() => _CareEventsScreenState();
}

class _CareEventsScreenState extends ConsumerState<CareEventsScreen> {
  @override
  void initState() {
    super.initState();
    // 화면을 연 순간 = 읽음. 프레임 뒤로 미뤄 build 중 상태 변경을 피한다.
    // refresh를 기다린 뒤에 읽음 처리해야 한다 — cascade로 이어 부르면
    // 목록이 아직 비어 있을 때 markAllSeen이 돌아 아무것도 읽음이 안 된다
    // (테스트가 실제로 잡아낸 결함).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(careEventsProvider.notifier);
      await notifier.refresh();
      await notifier.markAllSeen();
    });
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(careEventsProvider).events;

    return Scaffold(
      appBar: AppBar(title: const Text('알림')),
      body: events.isEmpty
          ? const _EmptyState()
          : RefreshIndicator(
              onRefresh: () async {
                final notifier = ref.read(careEventsProvider.notifier);
                await notifier.refresh();
                await notifier.markAllSeen();
              },
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                itemCount: events.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _CareEventCard(event: events[i]),
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none,
                size: 52, color: context.appMuted),
            const SizedBox(height: 14),
            Text('아직 알림이 없어요', style: AppText.title),
            const SizedBox(height: 6),
            Text(
              '실행 실패·위험 신호음·안부 신호가 생기면\n여기에 모아 보여드려요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appMuted, fontSize: 14),
            ),
          ],
        ),
      );
}

class _CareEventCard extends StatelessWidget {
  const _CareEventCard({required this.event});

  final RpiCareEvent event;

  // 종류별 아이콘·색 — 색만으로 구분하지 않도록 아이콘을 항상 함께 쓴다
  (IconData, Color, String) _style(BuildContext context) =>
      switch (event.kind) {
        'danger_sound' => (
            Icons.warning_amber_rounded,
            context.appDanger,
            '위험 신호음'
          ),
        'execution_failed' => (
            Icons.error_outline,
            context.appWarning,
            '실행 실패'
          ),
        'emergency_stop' => (
            Icons.front_hand_outlined,
            context.appWarning,
            '긴급 정지'
          ),
        'quiet_routine' => (
            Icons.favorite_outline,
            context.appPrimary,
            '안부 신호'
          ),
        _ => (Icons.info_outline, context.appMuted, '알림'),
      };

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return sameDay ? '오늘 $hm' : '${t.month}월 ${t.day}일 $hm';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = _style(context);
    return Semantics(
      label: '$label. ${event.message}. ${_formatTime(event.occurredAt)}',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTime(event.occurredAt),
                        style: TextStyle(
                            fontSize: 13, color: context.appMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    event.message,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
