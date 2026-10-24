import 'package:flutter/material.dart';

import '../../models/kiosk_history.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'tab_page.dart';

/// '기록' 탭(시안 B 10/24) — 최근 실행 결과(`GET /history`, 폰 기록과 같은 경로)를 읽기만 한다.
///
/// 줄마다 시각 · 무엇을 했나 · 결과 한 단어(완료·실패·멈춤·스스로 멈춤·확인 못 함, 연습이면 '연습 · 멈춤'처럼 함께). '완료'는 실제 실행에서 확인한 것만
/// ([KioskHistoryEntry.result] — 폰과 같은 확인 수준 규칙). 답하기·자세히는 폰 기록에서 한다.
class KioskHistoryView extends StatelessWidget {
  const KioskHistoryView({
    super.key,
    required this.entries,
    required this.now,
    this.loading = false,
    this.applianceNames = const {},
    this.onReload,
    this.onMenu,
  });

  /// 최신순 기록. null이면 못 불러왔다(불러오는 중이면 [loading]).
  final List<KioskHistoryEntry>? entries;
  final DateTime now;
  final bool loading;

  /// 기록에 가전 이름이 없을 때(옛 기록) 지금 목록에서 찾는 이름.
  final Map<String, String> applianceNames;
  final VoidCallback? onReload;

  /// 위 오른쪽 '메뉴'(처음 화면과 같은 창). null이면 두지 않는다.
  final VoidCallback? onMenu;

  static const kMoreOnPhone = '자세한 내용과 답하기는 휴대폰 앱 기록에서 볼 수 있어요';

  @override
  Widget build(BuildContext context) => KioskTabPage(
        key: const ValueKey('history-view'),
        title: '기록',
        note: kMoreOnPhone,
        loading: loading && entries == null,
        failed: entries == null,
        failedText: '기록을 불러오지 못했어요',
        emptyText: '아직 기록이 없어요',
        onReload: onReload,
        onMenu: onMenu,
        rows: [
          for (final e in entries ?? const <KioskHistoryEntry>[])
            _HistoryRow(
                key: ValueKey('history-${e.jobId}'),
                entry: e,
                now: now,
                name: e.applianceId == null ? null : applianceNames[e.applianceId]),
        ],
      );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({super.key, required this.entry, required this.now, this.name});

  final KioskHistoryEntry entry;
  final DateTime now;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final (word, tone) = entry.result;
    final (color, icon) = switch (tone) {
      KioskHistoryTone.confirmed => (KioskColors.confirmed, Icons.check_circle),
      KioskHistoryTone.attention => (KioskColors.warning, Icons.help_outline),
      KioskHistoryTone.stopped => (KioskColors.warning, Icons.front_hand_outlined),
      KioskHistoryTone.danger => (KioskColors.danger, Icons.cancel_outlined),
      KioskHistoryTone.neutral => (KioskColors.muted, Icons.science_outlined),
    };
    final title = entry.title(currentName: name);
    final when = [entry.whenLabel(now), if (entry.automatic) '자동'].join(' · ');
    return Semantics(
      container: true,
      label: '$when, $title, $word',
      excludeSemantics: true,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(when,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted)),
            Text(title,
                key: const ValueKey('history-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: KioskType.body, height: 1.25, fontWeight: FontWeight.w700, color: KioskColors.ink)),
          ]),
        ),
        const SizedBox(width: KioskSpace.sm),
        KioskTabBadge(key: const ValueKey('history-result'), label: word, color: color, icon: icon),
      ]),
    );
  }
}
