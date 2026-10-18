import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'connection_status.dart';
import 'estop_banner.dart';
import 'kiosk_text.dart';

/// 평소 화면 위쪽(화면 구조 개편 10/18) — 아이콘 4~5개(쉬기·설정·와이파이·누름 장치·콘센트) 대신
/// **상태 칩 하나**와 **메뉴** 하나.
///
/// - 상태 칩: 모두 괜찮으면 **두지 않는다**(사용자 결정 10/18 — 예전 '기기 모두 정상'). 문제가 있을 때만 앰버 '확인 필요 N',
///   본체에 닿지 않으면 '본체와 연결이 끊겼어요'. 아직 확인하지 못했으면 '연결을 확인하고 있어요'(정상이라고 하지 않는다).
///   비상 버튼 띠가 떠 있으면 연결 문제가 있을 때만 보인다(평가 14차 10/18).
///   문제가 하나면 누르면 그 연결 창이 바로 열리고, 그 밖에는 연결 목록 창이 열린다(항목을 누르면 그 연결 창).
/// - 메뉴: 화면 가운데 큰 창에 '잠시 쉬기'·'설정' — 설정은 구석에 두지 않는다(누르는 자리 48 이상).
/// 모름(unknown)은 정상처럼 두지 않고 '연결을 확인하고 있어요'(중립·물음표)로 말한다.

/// 연결 항목 짧은 이름.
String connectionShortName(String id) => switch (id) {
      'network' => '와이파이',
      'press' => '누름 장치',
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
/// 글이 null이면 칩을 두지 않는다(모두 괜찮음, 사용자 결정 10/18).
(String?, bool, ConnectionItem?) connectionSummary(List<ConnectionItem> items, {String? estopTitle}) {
  if (estopTitle != null) return (estopTitle, true, null);
  final shown = _shown(items);
  // 본체에 닿지 않으면 그 말 하나(나머지는 본체 너머라 볼 수 없다).
  if (shown.where(_isHubDown).firstOrNull case final hub?) {
    return ('본체와 연결이 끊겼어요', true, hub);
  }
  final problems = shown.where((i) => i.needsAttention).toList();
  // 문제가 있으면 '확인 필요 N'(사용자 결정 10/18) — 무엇이 왜인지는 누르면 보인다(하나면 그 연결 창, 여럿이면 연결 목록).
  if (problems.isNotEmpty) {
    return (kNeedsCheck(problems.length), true, problems.length == 1 ? problems.single : null);
  }
  // 볼 수 없음(unreachable — 첫 응답 전)도 정상이 아니다 — 모름과 같이 말한다(평가 7차 10/18). 숨기지 않는다:
  // 확인 못 한 것이 있는데 칩이 사라지면 '다 괜찮다'로 읽힌다.
  if (shown.any((i) => i.state == 'unknown' || i.state == 'unreachable')) {
    return (kCheckingConnections, false, null);
  }
  // 모두 괜찮으면 칩을 두지 않는다(사용자 결정 10/18 — 체크·'기기 모두 정상'도 없다). 글이 null이면 숨긴다.
  return (null, false, null);
}

/// 문제 칩 글 — '연결 확인 필요 2'(사용자 결정 10/18 '확인 필요 N', 평가 17차 10/18 — 칩은 연결 문제만 센다. 가전 문제(인덕션 멈춤 등)가
/// 같이 보일 때 '확인 필요 1'이 화면의 문제 수와 어긋나 보였다).
String kNeedsCheck(int n) => '연결 확인 필요 $n';

/// 아직 연결을 다 보지 못했을 때 칩 글(정상이라고 하지 않는다).
const kCheckingConnections = '연결을 확인하고 있어요';

/// 연결 하나의 문제를 쉬운 서술로(평가 3차 10/18 — 명사형 '연결 끊김' 대신). 칩을 읽는 화면 읽기 말에 쓴다.
String connectionProblemText(ConnectionItem p) {
  final name = connectionShortName(p.id);
  return p.state == 'error' ? '$name 연결이 끊겼어요' : '$name${p.id == 'press' ? '을' : '를'} 봐 주세요';
}

/// 원인이 하나일 때 칩 첫 줄 — 원인과 영향(평가 15차 10/18: 가전 4대가 '지금 못 써요'인데 칩은 '확인 필요 1'뿐이었다).
/// 누름 장치가 끊겨 못 쓰는 가전 수([pressImpact])를 알면 '누름 장치가 끊겨 가전 4대를 못 써요'(짧게 — 쉬는 중 칩과 함께여도 위 줄에
/// 들어가게), 모르면 '누름 장치 연결이 끊겼어요'.
String connectionCauseLine(ConnectionItem p, {int? pressImpact}) {
  if (p.id == 'press' && p.state == 'error' && pressImpact != null && pressImpact > 0) {
    return '누름 장치가 끊겨 가전 $pressImpact대를 못 써요';
  }
  return connectionProblemText(p);
}

/// 원인 줄이 있을 때 둘째 줄 끝의 짧은 다음 행동(평가 15차 10/18) — '확인 필요 1 · 해결 방법 보기'.
const kProblemHelpShort = '해결 방법 보기';

/// 연결 문제 칩 아래 다음 행동 한 줄(평가 7차 10/18).
const kProblemHelp = '눌러서 해결 방법 보기';

/// 상태 칩 — 높이 48 이상, 아이콘 + 짧은 말. 색만으로 말하지 않는다(문제면 아이콘 모양도 바뀐다).
class KioskIdleStatusChip extends StatelessWidget {
  const KioskIdleStatusChip({super.key, required this.items, required this.onTap, this.pressImpact});

  /// 문제 칩 두 줄의 글자 — 본문 단계(휴리스틱 평가 10/18).
  static const double _problemSize = KioskType.body;

  final List<ConnectionItem> items;
  final VoidCallback onTap;

  /// 누름 장치가 끊겨 지금 못 쓰는 가전 수(평가 15차 10/18) — 원인이 하나면 칩 첫 줄이 원인과 영향을 말한다. 모르면 null.
  final int? pressImpact;

  @override
  Widget build(BuildContext context) {
    // 비상 버튼 띠가 떠 있으면(평가 14차 10/18) — 띠가 이미 빨강으로 말한다. 글자 없는 '!' 원은 뜻 없는 장식이었다:
    // 연결이 다 괜찮으면 칩을 두지 않고, 연결 문제가 있으면 그 문제를 글자로(띠와 다른 사실이다). '모두 정상'은 띠와
    // 엇갈리므로(평가 4차 10/18) 띠 아래에서는 쓰지 않는다.
    if (KioskEstopScope.shownOf(context)) {
      final (_, problem, _) = connectionSummary(items);
      if (!problem) return const SizedBox.shrink();
    }
    final (summary, problem, direct) = connectionSummary(items);
    // 모두 괜찮으면 칩이 없다(사용자 결정 10/18). 메뉴 단추는 그대로 같은 자리.
    if (summary == null) return const SizedBox.shrink();
    final text = summary;
    // 원인이 하나면 첫 줄은 원인과 영향, 둘째 줄에 '확인 필요 1 · 눌러서 해결 방법 보기'(평가 15차 10/18). 본체 끊김은 칩 글이 이미 원인이다.
    final cause = problem && direct != null && !_isHubDown(direct)
        ? connectionCauseLine(direct, pressImpact: pressImpact)
        : null;
    final unknown = !problem;
    // 연결 문제는 앰버.
    final tone = KioskColors.warning;
    final color = problem ? tone : KioskColors.muted;
    // 화면 읽기는 무엇이 문제인지까지 읽는다('확인 필요 1. 누름 장치 연결이 끊겼어요').
    final what = [
      for (final i in _shown(items))
        if (i.needsAttention && !_isHubDown(i)) connectionProblemText(i),
    ];
    return Semantics(
      button: true,
      label: problem
          ? [if (cause != null) cause, text, if (cause == null) ...what, kProblemHelp].join('. ')
          : '$text. 연결 자세히 보기',
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
              padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(unknown ? Icons.help_outline : Icons.error_outline, size: 24, color: color),
                  ...[
                    const SizedBox(width: KioskSpace.xs),
                    // 문제가 있으면 바로 아래 다음 행동 한 줄(평가 7차 10/18 — '누름 장치 연결이 끊겼어요'만 있고 할 일이 없었다).
                    // 칩 전체가 누르는 자리라 이 줄을 눌러도 같은 연결 창이 열린다.
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(cause ?? text,
                            key: cause == null ? null : const ValueKey('idle-problem-cause'),
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                                // 문제면 본문 크기(휴리스틱 평가 10/18 — 1~2 m에서 작은 글자는 읽히지 않았다).
                                fontSize: problem ? _problemSize : KioskType.caption,
                                height: problem ? 1.15 : null,
                                fontWeight: problem ? FontWeight.w700 : FontWeight.w500,
                                color: problem ? Colors.white : KioskColors.muted)),
                        if (problem)
                          Row(
                            key: const ValueKey('idle-problem-help'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (cause != null) ...[
                                Text(text,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                        fontSize: _problemSize,
                                        height: 1.15,
                                        fontWeight: FontWeight.w700,
                                        color: tone)),
                                Text(' · ',
                                    style: TextStyle(
                                        fontSize: _problemSize, height: 1.15, color: KioskColors.muted)),
                              ],
                              // 할 일은 흰 글자·본문 크기(휴리스틱 평가 10/18 — 회색 작은 글자라 눌러 볼 수 있다는 것을 놓쳤다).
                              Text(cause != null ? kProblemHelpShort : kProblemHelp,
                                  key: const ValueKey('idle-problem-help-text'),
                                  maxLines: 1,
                                  softWrap: false,
                                  style: TextStyle(
                                      fontSize: _problemSize,
                                      height: 1.15,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white)),
                              Icon(Icons.chevron_right, size: _problemSize + 3, color: tone),
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
        label: '메뉴. 잠시 쉬기, 설정, 연결, 사용 방법',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('idle-menu'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
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
                  // '닫기'는 제목 줄 오른쪽(휴리스틱 평가 10/18 — 메뉴에 '사용 방법'을 더하자 아래 '닫기'가 화면 가장자리 여백
                  // 밖으로 밀렸다). 누르는 자리 48 이상은 그대로.
                  Row(children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: KioskType.body,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                    TextButton(
                      key: const ValueKey('idle-sheet-close'),
                      onPressed: onClose,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(120, 48),
                          foregroundColor: Colors.white),
                      child: const Text('닫기',
                          style: TextStyle(fontSize: KioskType.body)),
                    ),
                  ]),
                  const SizedBox(height: KioskSpace.xs),
                  ...children,
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
                                style: TextStyle(
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
                        decoration: BoxDecoration(
                            color: KioskColors.warning, shape: BoxShape.circle),
                        child: Text('!',
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                                fontSize: KioskType.caption,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: KioskColors.onAccent)),
                      ),
                    Icon(Icons.chevron_right, size: 28, color: KioskColors.muted),
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
