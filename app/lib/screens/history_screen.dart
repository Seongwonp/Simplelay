import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/command_result.dart';
import '../providers/appliance_provider.dart';
import '../providers/clock_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 실행 기록 — 공감지능(패턴 학습)의 근거 데이터와 폐루프의 회복 기록
/// ("재시도 N회 후 성공")을 사용자에게 그대로 보여준다.
final historyProvider =
    FutureProvider.autoDispose<List<RpiHistoryEntry>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const [];
  return api.history();
});

/// 날짜별 로그가 아니라 **무엇을 했고 결과가 어땠는지**가 먼저다.
///
/// 날짜는 구획 제목으로만 쓴다(오늘·어제·M월 D일). 한 건은 카드가 아니라
/// 행이다 -- 카드로 감싸면 모든 기록의 깊이가 같아져서, 끝이 안 좋았던
/// 실행이 눈에 띄지 않는다. 결과는 아이콘(모양)과 문장이 같이 말한다.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(historyProvider);
    final now = ref.watch(nowProvider)();
    final installed = ref.watch(installedAppliancesProvider);

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
                  text: '아직 실행 기록이 없어요.\n가전을 조작하면 여기에 기록돼요.',
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    for (final section in _groupByDay(entries, now)) ...[
                      const SizedBox(height: 16),
                      Text(section.label, style: AppText.title),
                      const SizedBox(height: 4),
                      for (var i = 0; i < section.entries.length; i++) ...[
                        _HistoryRow(
                          entry: section.entries[i],
                          applianceName: _applianceName(
                              installed, section.entries[i].applianceId),
                        ),
                        if (i < section.entries.length - 1)
                          Divider(height: 1, color: context.appBorderFaint),
                      ],
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  /// 기록이 가리키는 가전 이름. 모르면 null -- 지어내지 않는다(지웠거나,
  /// 이 열이 생기기 전 기록이다).
  static String? _applianceName(List installed, String? id) {
    if (id == null) return null;
    for (final a in installed) {
      if (a.id == id) return a.displayName as String;
    }
    return null;
  }
}

class _DaySection {
  const _DaySection(this.label, this.entries);
  final String label;
  final List<RpiHistoryEntry> entries;
}

/// 서버가 최신순으로 준 목록을 날짜 구획으로 나눈다. 순서는 그대로다.
List<_DaySection> _groupByDay(List<RpiHistoryEntry> entries, DateTime now) {
  final sections = <_DaySection>[];
  for (final e in entries) {
    final label = _dayLabel(e.finishedAt, now);
    if (sections.isNotEmpty && sections.last.label == label) {
      sections.last.entries.add(e);
    } else {
      sections.add(_DaySection(label, [e]));
    }
  }
  return sections;
}

String _dayLabel(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '어제';
  return '${t.month}월 ${t.day}일';
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
                      fontSize: 16,
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
                  style: TextStyle(fontSize: 14, color: context.appMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 결과 하나를 아이콘(모양)과 문장으로. 색은 그 위에 얹는다.
({IconData icon, Color color, String sentence}) _outcome(
  BuildContext context,
  RpiHistoryEntry entry,
) {
  // 새 서버는 outcome을 준다(정지 요청 / 안전 정지 / ThinQ 확인 못 함을 가른다).
  if (entry.outcome != null) {
    final thinq = entry.route == 'thinq';
    switch (resultKindOf(outcome: entry.outcome)) {
      case ResultKind.success:
        return (
          icon: Icons.check_circle,
          color: context.appSuccess,
          sentence: thinq ? '가전 상태를 확인했어요' : '버튼 조작을 마쳤어요',
        );
      case ResultKind.stopped:
        return (
          icon: Icons.front_hand,
          color: context.appWarning,
          sentence: '정지됨',
        );
      case ResultKind.safetyStop:
        return (
          icon: Icons.front_hand,
          color: context.appWarning,
          sentence: entry.termination == 'retries_exhausted'
              ? '다시 눌러도 확인하지 못해 안전 정지'
              : '안전 정지',
        );
      case ResultKind.unconfirmed:
        // 실패가 아니다 -- 보냈지만 가전 상태로 확인하지 못했다.
        return (
          icon: Icons.help_outline,
          color: context.appWarning,
          sentence: '보냈지만 확인하지 못했어요',
        );
      case ResultKind.failed:
        return (
          icon: Icons.cancel,
          color: context.appDanger,
          sentence: thinq
              ? '실행 안 됨'
              : entry.termination == 'retries_exhausted'
                  ? '다시 눌러도 확인하지 못했어요'
                  : '실패',
        );
    }
  }
  // 옛 서버 — 종전 판정.
  switch (entry.status) {
    case 'succeeded':
      return (
        icon: Icons.check_circle,
        color: context.appSuccess,
        sentence: '버튼 조작을 마쳤어요',
      );
    case 'safety_stopped':
      // 사용자가 멈춘 것과 안전 장치가 멈춘 것은 다른 이야기다. 서버가
      // 종료 사유를 준 기록에서만 나눈다 -- 없으면 아는 척하지 않는다.
      return entry.termination == 'stopped_by_user'
          ? (
              icon: Icons.front_hand,
              color: context.appWarning,
              sentence: '직접 멈췄어요',
            )
          : (
              icon: Icons.front_hand,
              color: context.appWarning,
              sentence: '안전 정지',
            );
    default:
      return entry.termination == 'retries_exhausted'
          ? (
              icon: Icons.cancel,
              color: context.appDanger,
              sentence: '다시 눌러도 확인하지 못했어요',
            )
          : (
              icon: Icons.cancel,
              color: context.appDanger,
              sentence: '실패',
            );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.applianceName});

  final RpiHistoryEntry entry;

  /// 어느 가전이었는지. 모르면 null이고 말하지 않는다.
  final String? applianceName;

  @override
  Widget build(BuildContext context) {
    final kind = resultKindOf(outcome: entry.outcome, status: entry.status);
    final succeeded = kind == ResultKind.success;
    // 버튼 단계·'버튼으로 직접 조작'은 물리 경로의 이야기다. ThinQ 기록과
    // 확인 못 함(실패 아님)은 펼치지 않는다.
    final expand = !succeeded &&
        kind != ResultKind.unconfirmed &&
        entry.route != 'thinq';
    final o = _outcome(context, entry);
    final route = routeLabel(entry.route);
    final confirmation = confirmationLabel(
      route: entry.route,
      receipt: entry.receipt,
      confirmation: entry.confirmation,
      kind: kind,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(o.icon, color: o.color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayTitle,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    entry.executionMode == 'mock' ? '모의 실행'
                        : entry.executionMode == 'real' ? '실기기 실행' : '실행 환경 미확인',
                    _hm(entry.finishedAt),
                    o.sentence,
                    if (applianceName != null) applianceName!,
                  ].join(' · '),
                  style: TextStyle(fontSize: 14, color: context.appMuted),
                ),
                // 경로·확인 수준 열. 이 열이 생기기 전 기록(unknown)은 말하지 않는다.
                if (route != null || confirmation != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (route != null) '경로 $route',
                      if (confirmation != null) '확인 $confirmation',
                    ].join(' · '),
                    style: TextStyle(fontSize: 14, color: context.appMuted),
                  ),
                ],
                if (entry.detail.isNotEmpty && !succeeded) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.detail,
                    style: TextStyle(fontSize: 14, color: context.appMuted),
                  ),
                ],
                if (entry.retryCount > 0 && succeeded) ...[
                  const SizedBox(height: 6),
                  // 폐루프의 핵심 증거 — 실패를 스스로 재시도로 회복했다.
                  Row(
                    children: [
                      Icon(Icons.refresh, size: 16, color: context.appSuccess),
                      const SizedBox(width: 6),
                      Text(
                        '재시도 ${entry.retryCount}회 후 성공',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.appSuccess,
                        ),
                      ),
                    ],
                  ),
                ],

                // 끝이 안 좋았던 실행만 안을 펼친다. 성공한 이력까지
                // 단계를 늘어놓으면 목록이 다시 개발 도구처럼 보인다.
                if (expand) ...[
                  const SizedBox(height: 10),
                  _StepBreakdown(buttons: entry.buttons),
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
    );
  }
}
