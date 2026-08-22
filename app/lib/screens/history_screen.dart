import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 실행 기록 타임라인 — 공감지능(패턴 학습)의 근거 데이터와 폐루프의
/// 회복 기록("재시도 N회 후 성공")을 사용자에게 그대로 보여준다.
final historyProvider =
    FutureProvider.autoDispose<List<RpiHistoryEntry>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const [];
  return api.history();
});

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('실행 기록')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(historyProvider.future),
        child: historyAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _Message(
            icon: Icons.wifi_off,
            text: '기록을 불러오지 못했어요.\n연결을 확인하고 아래로 당겨 새로고침해주세요.',
          ),
          data: (entries) => entries.isEmpty
              ? _Message(
                  icon: Icons.history,
                  text: '아직 실행 기록이 없어요.\n가전을 조작하면 여기에 기록됩니다.',
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _HistoryTile(entry: entries[i]),
                ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // RefreshIndicator가 빈 화면에서도 동작하도록 스크롤 가능 영역 유지
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 40, color: context.appMuted),
                  const SizedBox(height: 12),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.appMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});
  final RpiHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final succeeded = entry.status == 'succeeded';
    final stopped = entry.status == 'safety_stopped';
    final (color, icon, statusLabel) = succeeded
        ? (AppColors.success, Icons.check_circle, '완료')
        : stopped
            ? (AppColors.warning, Icons.front_hand, '안전 정지')
            : (AppColors.danger, Icons.error, '실패');

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.displayTitle, style: AppText.title),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatTime(entry.finishedAt)} · $statusLabel',
                    style:
                        TextStyle(fontSize: 12, color: context.appMuted),
                  ),
                  if (entry.retryCount > 0 && succeeded) ...[
                    const SizedBox(height: 8),
                    // 폐루프의 핵심 증거 — 실패를 스스로 재시도로 회복했다
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '재시도 ${entry.retryCount}회 후 성공',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return sameDay ? '오늘 $hm' : '${t.month}월 ${t.day}일 $hm';
  }
}
