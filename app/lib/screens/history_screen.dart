import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/command_result.dart';
import '../models/display_status.dart';
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
  // 허브에 닿지 않으면 조회하지 못한 것이다 — '기록 없음'으로 말하지 않는다.
  if (api == null) throw StateError('hub not connected');
  return api.history();
});

/// 날짜별 로그가 아니라 **무엇을 했고 결과가 어땠는지**가 먼저다.
///
/// 읽는 순서(2026-10-13 B안): 날짜(구획 제목) → 제목 → 결과 → 시각 → 모의 여부 →
/// 다음 행동 → 보조 정보(버튼별 결과·직접 조작 입구). 한 건은 카드가 아니라 행이다.
/// 문구는 `models/display_status.dart`가 정한다 — 목적을 추정하지 않고, 데이터가
/// 아는 수준까지만 말한다.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(historyProvider);
    final now = ref.watch(nowProvider)();
    final installed = ref.watch(installedAppliancesProvider);

    return Scaffold(
      // 탭 제목은 홈('우리 집')과 같은 굵은 큰 제목(UI 평가 10/17).
      appBar: AppBar(title: Text('기록', style: AppText.heading)),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(historyProvider.future),
        child: historyAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _Message(
            icon: Icons.wifi_off,
            text: '기록을 불러오지 못했어요.\n연결을 확인하고 아래로 당겨 새로고침해 주세요.',
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
                        // jobId가 다르면 같은 시각이라도 다른 행이다(합치지 않는다).
                        _HistoryRow(
                          key: ValueKey('history-${section.entries[i].jobId}'),
                          entry: section.entries[i],
                          // 실행할 때의 이름이 먼저다 — 나중에 이름·모드가 바뀌어도 그때 이름(결함 ②).
                          applianceName: section.entries[i].applianceName ??
                              _applianceName(
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
  const _StepBreakdown({required this.buttons, this.notPressed = false});

  final List<RpiHistoryButton> buttons;

  /// 모션 장치가 걸려 멈춘 실행(abortReason) — 실패한 단계는 누르지 못한 것이다.
  /// "확인 못 함"(눌렀을 수도 있음)으로 말하지 않는다(2026-10-14 UX).
  final bool notPressed;

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
                  b.success
                      ? Icons.check_circle_outline
                      : notPressed
                          ? Icons.remove_circle_outline
                          : Icons.help_outline,
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
                      : notPressed
                          ? '누르지 않음'
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

/// 결과 종류의 아이콘(모양)과 색. 뜻은 언제나 옆의 문장이 말한다.
({IconData icon, Color color}) _look(BuildContext context, ResultKind kind) =>
    switch (kind) {
      ResultKind.success => (icon: Icons.check_circle, color: context.appSuccess),
      ResultKind.stopped ||
      ResultKind.safetyStop =>
        (icon: Icons.front_hand, color: context.appWarning),
      ResultKind.unconfirmed => (icon: Icons.help_outline, color: context.appWarning),
      ResultKind.failed => (icon: Icons.cancel, color: context.appDanger),
    };

/// ThinQ 기록의 수신 수준 한 줄(접수됨·받았는지 확인이 필요해요 등). 물리 기록은
/// 결과 문장이 이미 확인 수준을 말하므로 따로 적지 않는다("물리 버튼"·"확인 근거
/// 없음" 같은 시스템 용어를 앞에 내지 않는다).
String? _thinqReceiptLine(RpiHistoryEntry e, ResultKind kind) {
  if (e.route != 'thinq') return null;
  // 모의는 결과 문장("연습 · ○○에 보내지 않았어요")이 이미 다 말한다 — 접수 줄을 겹치지 않는다.
  if (e.executionMode == 'mock') return null;
  // 이미 목표값이면 위 결과 문장이 다 말한다 — 같은 뜻을 두 줄로 쓰지 않는다(UI 평가 10/17).
  if (e.confirmation == 'already_at_target') return 'ThinQ';
  final label = confirmationLabel(
    route: e.route,
    receipt: e.receipt,
    confirmation: e.confirmation,
    kind: kind,
    executionMode: e.executionMode,
  );
  return label == null ? 'ThinQ' : 'ThinQ · $label';
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.entry,
    required this.applianceName,
  });

  final RpiHistoryEntry entry;

  /// 어느 가전이었는지. 모르면 null이고 말하지 않는다.
  final String? applianceName;

  @override
  Widget build(BuildContext context) {
    final result = historyResult(entry, applianceName: applianceName);
    final kind = result.kind;
    final succeeded = kind == ResultKind.success;
    // 버튼 단계·'버튼으로 직접 조작'은 물리 경로의 이야기다. ThinQ 기록과
    // 확인 못 함(실패 아님)은 펼치지 않는다.
    final expand = !succeeded &&
        kind != ResultKind.unconfirmed &&
        entry.route != 'thinq';
    // 연습(모의) 성공은 중립 아이콘 — 성공 체크는 실제로 한 일에만 붙인다(외부 평가 10/16 p03).
    // 이미 목표값(보내지 않음)도 중립 — 성공 체크는 실제로 바꾼 일에만(UI 평가 10/17).
    final look = succeeded && entry.executionMode == 'mock'
        ? (icon: Icons.science_outlined, color: context.appMuted)
        : succeeded && entry.confirmation == 'already_at_target'
            ? (icon: Icons.info_outline, color: context.appMuted)
            : _look(context, kind);
    final title = historyTitle(entry, applianceName: applianceName);
    final rawName = applianceName;
    // 모의 기록은 '연습' 한 줄이 말한다 — 이름의 "(모의)"를 되풀이하지 않는다(표시만).
    final name = rawName != null && entry.executionMode == 'mock'
        ? withoutMockMark(rawName)
        : rawName;
    // 제목이 이미 가전 이름을 말하면 시각 줄에서 되풀이하지 않는다.
    final timeLine = [
      _hm(entry.finishedAt),
      historySource(entry),
      if (name != null && !title.contains(name)) name,
    ].join(' · ');
    final receipt = _thinqReceiptLine(entry, kind);
    final muted = TextStyle(fontSize: 14, color: context.appMuted);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: ExcludeSemantics(
                    child: Icon(look.icon, color: look.color, size: 20)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  result.sentence,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: look.color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(timeLine, style: muted),
          if (result.mockNote case final note?) ...[
            const SizedBox(height: 2),
            Text(note, style: muted),
          ],
          if (receipt != null) ...[
            const SizedBox(height: 2),
            Text(receipt, style: muted),
          ],
          if (result.next case final next?) ...[
            const SizedBox(height: 6),
            Text(
              next,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
          // 연습(모의) 기록은 위 한 줄이 이미 말한다 — 서버 설명('명령을 보냈어요 …')을 겹치면 어긋난다(10/14).
          if (entry.detail.isNotEmpty && !succeeded && entry.executionMode != 'mock') ...[
            const SizedBox(height: 2),
            Text(entry.detail, style: muted),
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
            _StepBreakdown(
                buttons: entry.buttons, notPressed: entry.abortReason != null),
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
    );
  }
}
