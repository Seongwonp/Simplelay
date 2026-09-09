import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

/// 어느 단계까지 갔는지 — 성공 / 확인하지 못함 / 시도 횟수.
///
/// 폐루프는 버튼마다 눌림을 확인하고 필요하면 다시 누른다. 실패했을 때
/// **어디서** 멈췄는지는 그 기록에 이미 들어 있는데 화면이 버리고 있었다.
/// 가전 앞에서 무엇을 이어서 해야 하는지가 여기서 갈린다.
class _StepBreakdown extends StatelessWidget {
  const _StepBreakdown({required this.buttons});

  final List<RpiHistoryButton> buttons;

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in buttons)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  b.success ? Icons.check_circle_outline : Icons.help_outline,
                  size: 18,
                  color: b.success ? context.appSuccess : context.appWarning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    b.button,
                    style: TextStyle(
                      color: b.success ? null : context.appMuted,
                    ),
                  ),
                ),
                Text(
                  // '눌렀지만 확인 못 함'과 '아예 못 누름'을 화면이
                  // 구분할 재료는 없다 -- 확인 여부까지만 말한다.
                  b.success
                      ? (b.attempts > 1 ? '${b.attempts}번 만에 확인' : '확인됨')
                      : '확인 못 함',
                  style: TextStyle(fontSize: 13, color: context.appMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});
  final RpiHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final succeeded = entry.status == 'succeeded';
    final stopped = entry.status == 'safety_stopped';
    final (color, icon, statusLabel) = succeeded
        ? (context.appSuccess, Icons.check_circle, '완료')
        : stopped
            ? (context.appWarning, Icons.front_hand, '안전 정지')
            : (context.appDanger, Icons.error, '실패');

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
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: context.appSuccess.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: context.appSuccess.withValues(alpha: 0.35),
                        ),
                      ),
                      // 폐루프가 실제로 회복했다는 유일한 기록 증거 —
                      // 11px는 화면 미러링 시 심사석에서 읽히지 않았다
                      child: Text(
                        '재시도 ${entry.retryCount}회 후 성공',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.appSuccess,
                        ),
                      ),
                    ),
                  ],

                  // 끝이 안 좋았던 실행만 안을 펼친다. 성공한 이력까지
                  // 단계를 늘어놓으면 목록이 다시 개발 도구처럼 보인다.
                  if (!succeeded) ...[
                    const SizedBox(height: 10),
                    _StepBreakdown(buttons: entry.buttons),
                    const SizedBox(height: 8),
                    // 읽고 나서 할 수 있는 일을 남긴다. 무엇이 안 됐는지만
                    // 알려주고 끝내면 사용자는 앱을 닫는 것 말고 할 게 없다.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/manual-control'),
                        icon: const Icon(Icons.grid_view_rounded, size: 18),
                        label: const Text('버튼으로 직접 조작'),
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
