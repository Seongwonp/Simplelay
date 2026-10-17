import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'connection_status.dart';
import 'estop_banner.dart';
import 'kiosk_text.dart';

/// 평소 화면 위쪽(화면 구조 개편 10/18) — 아이콘 4~5개(쉬기·설정·와이파이·작은 팔·콘센트) 대신
/// **상태 칩 하나**와 **메뉴** 하나.
///
/// - 상태 칩: 모두 괜찮으면 '모두 정상'(중립), 문제가 있을 때만 앰버로 무엇이 문제인지('작은 팔 연결이 끊겼어요').
///   문제가 하나면 누르면 그 연결 창이 바로 열리고, 그 밖에는 연결 목록 창이 열린다(항목을 누르면 그 연결 창).
/// - 메뉴: 화면 가운데 큰 창에 '잠시 쉬기'·'설정' — 설정은 구석에 두지 않는다(누르는 자리 48 이상).
/// 모름(unknown)은 정상처럼 두지 않고 '연결을 확인하고 있어요'(중립·물음표)로 말한다.

/// 연결 항목 짧은 이름.
String connectionShortName(String id) => switch (id) {
      'network' => '와이파이',
      'press' => '작은 팔',
      'plug' => '전기 플러그',
      _ => '연결',
    };

/// 칩에 보일 항목(설치 안 한 콘센트는 문제가 아니라 빼고 본다).
List<ConnectionItem> _shown(List<ConnectionItem> items) => [
      for (final i in items)
        if (!(i.id == 'plug' && i.state == 'not_installed')) i,
    ];

/// 본체(/health)에 닿지 않으면 지난번에 받은 연결 목록을 믿지 않는다(평가 7차 10/18) — 예전에는 본체에 닿지 않아
/// 가전을 누르면 연결 창이 뜨는데 위 칩은 지난 목록대로 '모두 정상'이었다. 와이파이 자리에 '본체와 연결되지 않았어요'를
/// 세우고 나머지는 볼 수 없다고만 둔다. 아직 한 번도 못 받았으면(모두 볼 수 없음) 그대로 둔다 — '확인하고 있어요'.
List<ConnectionItem> connectionsForDisplay(List<ConnectionItem> items, {required bool connected}) {
  if (connected) return items;
  if (items.every((i) => i.state == 'unreachable')) return items;
  return [
    ConnectionItem.hubUnreachable,
    for (final i in items)
      if (i.id != 'network')
        i.state == 'not_installed' || i.state == 'unreachable'
            ? i
            : ConnectionItem(
                id: i.id,
                state: 'unreachable',
                title: '${connectionShortName(i.id)} 상태를 볼 수 없어요',
                message: '본체와 연결되면 볼 수 있어요.'),
  ];
}

bool _isHubDown(ConnectionItem i) =>
    i.id == 'network' && i.state == 'error' && i.title == ConnectionItem.hubUnreachable.title;

/// 상태 칩 요약 — (글, 문제 여부, 바로 열 항목).
///
/// 비상 버튼이 걸려 있으면([estopTitle], 위 빨간 띠 제목) 연결이 다 괜찮아도 '모두 정상'이 아니다 — 띠와 같은 말을
/// 칩에도 쓴다(평가 4차 10/18: 빨간 띠 아래 칩이 '모두 정상'이라 서로 다른 말을 했다).
(String, bool, ConnectionItem?) connectionSummary(List<ConnectionItem> items, {String? estopTitle}) {
  if (estopTitle != null) return (estopTitle, true, null);
  final shown = _shown(items);
  // 본체에 닿지 않으면 그 말 하나(나머지는 본체 너머라 볼 수 없다).
  if (shown.where(_isHubDown).firstOrNull case final hub?) {
    return ('본체와 연결이 끊겼어요', true, hub);
  }
  final problems = shown.where((i) => i.needsAttention).toList();
  if (problems.length == 1) {
    final p = problems.single;
    // 명사형('연결 끊김') 대신 쉬운 서술(평가 3차 10/18).
    final name = connectionShortName(p.id);
    final text = p.state == 'error'
        ? '$name 연결이 끊겼어요'
        : '$name${p.id == 'press' ? '을' : '를'} 봐 주세요';
    return (text, true, p);
  }
  if (problems.length > 1) return ('연결 ${problems.length}곳을 봐 주세요', true, null);
  // 볼 수 없음(unreachable — 첫 응답 전)도 정상이 아니다 — 모름과 같이 말한다(평가 7차 10/18).
  if (shown.any((i) => i.state == 'unknown' || i.state == 'unreachable')) {
    return ('연결을 확인하고 있어요', false, null);
  }
  return ('모두 정상', false, null);
}

/// 연결 문제 칩 아래 다음 행동 한 줄(평가 7차 10/18).
const kProblemHelp = '눌러서 해결 방법 보기';

/// 상태 칩 — 높이 48 이상, 아이콘 + 짧은 말. 색만으로 말하지 않는다(문제면 아이콘 모양도 바뀐다).
class KioskIdleStatusChip extends StatelessWidget {
  const KioskIdleStatusChip({super.key, required this.items, required this.onTap});

  final List<ConnectionItem> items;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final estop = KioskEstopScope.titleOf(context);
    final (text, problem, _) = connectionSummary(items, estopTitle: estop);
    final unknown = !problem && text != '모두 정상';
    // 비상 버튼은 빨강(위 띠와 같은 색), 연결 문제는 앰버.
    final tone = estop != null ? KioskColors.danger : KioskColors.warning;
    final color = problem ? tone : KioskColors.muted;
    return Semantics(
      button: true,
      label: problem && estop == null ? '$text. $kProblemHelp' : '$text. 연결 자세히 보기',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('idle-status-chip'),
        color: problem
            ? tone.withValues(alpha: KioskSizes.bandTint)
            : KioskColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
              color: problem ? tone : KioskColors.border,
              width: problem ? 2 : 1),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52, minWidth: 52),
            child: Padding(
              // 비상 버튼 띠가 있으면 칩은 아이콘만(평가 5차 10/18 — 띠와 칩이 같은 문장을 두 번 했다). 누르는 자리는 52.
              padding: EdgeInsets.symmetric(horizontal: estop != null ? KioskSpace.sm : KioskSpace.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                      estop != null
                          ? Icons.report
                          : problem
                          ? Icons.error_outline
                          : unknown
                              ? Icons.help_outline
                              : Icons.check_circle_outline,
                      size: estop != null ? 28 : 24,
                      color: color),
                  if (estop == null) ...[
                    const SizedBox(width: KioskSpace.xs),
                    // 문제가 있으면 바로 아래 다음 행동 한 줄(평가 7차 10/18 — '작은 팔 연결이 끊겼어요'만 있고 할 일이 없었다).
                    // 칩 전체가 누르는 자리라 이 줄을 눌러도 같은 연결 창이 열린다.
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(text,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                                fontSize: KioskType.caption,
                                height: problem ? 1.15 : null,
                                fontWeight: problem ? FontWeight.w700 : FontWeight.w500,
                                color: problem ? Colors.white : KioskColors.muted)),
                        if (problem)
                          Row(
                            key: const ValueKey('idle-problem-help'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(kProblemHelp,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                      fontSize: KioskType.caption,
                                      height: 1.15,
                                      color: KioskColors.muted)),
                              Icon(Icons.chevron_right, size: KioskType.caption + 3, color: tone),
                            ],
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 메뉴 단추 — 아이콘 아래 이름 '메뉴'. 누르는 자리 64x64(48 이상).
class KioskIdleMenuButton extends StatelessWidget {
  const KioskIdleMenuButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '메뉴. 잠시 쉬기와 설정',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('idle-menu'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: const SizedBox(
            width: 64,
            height: 64,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.menu, size: 28, color: KioskColors.muted),
              Text('메뉴',
                  maxLines: 1,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                      fontSize: KioskType.caption, height: 1.1, color: KioskColors.muted)),
            ]),
          ),
        ),
      );
}

/// 화면 가운데 큰 창(메뉴·연결 목록) — 어두운 막 위 카드, 아래 '닫기'. 바깥을 눌러도 닫힌다.
class KioskIdleSheet extends StatelessWidget {
  const KioskIdleSheet({
    super.key,
    required this.title,
    required this.children,
    required this.onClose,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.6)),
          ),
        ),
        Center(
          child: Container(
            key: const ValueKey('idle-sheet'),
            width: 460,
            padding: const EdgeInsets.fromLTRB(
                KioskSpace.md, KioskSpace.md, KioskSpace.md, KioskSpace.sm),
            decoration: BoxDecoration(
              color: KioskColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: KioskColors.border),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: KioskType.body,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: KioskSpace.sm),
                  ...children,
                  const SizedBox(height: KioskSpace.xs),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const ValueKey('idle-sheet-close'),
                      onPressed: onClose,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(120, 48),
                          foregroundColor: Colors.white),
                      child: const Text('닫기',
                          style: TextStyle(fontSize: KioskType.body)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]);
}

/// 큰 창의 한 줄 — 아이콘 · 이름(· 아래 작은 줄) · 오른쪽 화살표. 높이 64(48 이상).
class KioskSheetRow extends StatelessWidget {
  const KioskSheetRow({
    super.key,
    required this.icon,
    required this.label,
    this.sub,
    this.iconColor = Colors.white,
    this.badge = false,
    this.badgeKey,
    required this.onTap,
    this.semanticsLabel,
  });

  final IconData icon;
  final String label;
  final String? sub;
  final Color iconColor;

  /// 문제 표시('!' 배지) — 색만으로 말하지 않는다.
  final bool badge;
  final Key? badgeKey;
  final VoidCallback onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: KioskSpace.xs),
        child: Semantics(
          button: true,
          label: semanticsLabel ?? [label, if (sub != null) sub].join('. '),
          excludeSemantics: true,
          child: Material(
            color: KioskColors.surface2,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: KioskSpace.md, vertical: KioskSpace.xs),
                  child: Row(children: [
                    Icon(icon, size: 28, color: iconColor),
                    const SizedBox(width: KioskSpace.sm),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  fontSize: KioskType.body,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          if (sub != null && sub!.isNotEmpty)
                            KioskText(sub!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: KioskType.caption,
                                    color: KioskColors.muted)),
                        ],
                      ),
                    ),
                    if (badge)
                      Container(
                        key: badgeKey,
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        margin: const EdgeInsets.only(right: KioskSpace.xs),
                        decoration: const BoxDecoration(
                            color: KioskColors.warning, shape: BoxShape.circle),
                        child: const Text('!',
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                                fontSize: KioskType.caption,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: KioskColors.onAccent)),
                      ),
                    const Icon(Icons.chevron_right, size: 28, color: KioskColors.muted),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// 연결 목록 창의 줄들 — 항목마다 이름·지금 상태(서버 문장). 키는 `conn-<id>`, 문제면 `conn-badge-<id>`.
List<Widget> connectionRows(List<ConnectionItem> items, ValueChanged<ConnectionItem> onOpen) => [
      for (final item in _shown(items))
        KioskSheetRow(
          key: ValueKey('conn-${item.id}'),
          icon: connectionIcon(item),
          iconColor: item.needsAttention ? KioskColors.warning : KioskColors.muted,
          label: connectionShortName(item.id),
          sub: item.state == 'unknown' ? '확인하지 못했어요' : item.title,
          badge: item.needsAttention,
          badgeKey: ValueKey('conn-badge-${item.id}'),
          onTap: () => onOpen(item),
        ),
    ];
