import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 키오스크 아래 탭(시안 B 10/24 — 폰과 같은 네 갈래).
enum KioskTab { home, appliances, auto, history }

/// 탭 이름 — 화면 글자와 화면 읽기에 같이 쓴다.
String kioskTabName(KioskTab tab) => switch (tab) {
      KioskTab.home => '홈',
      KioskTab.appliances => '가전',
      KioskTab.auto => '자동 실행',
      KioskTab.history => '기록',
    };

IconData _tabIcon(KioskTab tab) => switch (tab) {
      KioskTab.home => Icons.home_outlined,
      KioskTab.appliances => Icons.grid_view_outlined,
      KioskTab.auto => Icons.schedule,
      KioskTab.history => Icons.format_list_bulleted,
    };

/// 아래 탭 줄 — 선택된 탭은 아이콘 뒤 민트 알약 + 청록 굵은 글자(색만으로 말하지 않는다 — 화면 읽기는 '선택됨').
///
/// 평소·가전 고르기·가전 조작·자동 실행·기록 화면에서만 보인다(kiosk_screen이 가른다). 제안·확인·누르는 중·결과·정지 대기와
/// 정지·승인이 앞서야 하는 창이 떠 있으면 두지 않는다 — 탭을 눌러 그 화면을 벗어나지 않게.
class KioskTabBar extends StatelessWidget {
  const KioskTabBar({super.key, required this.current, required this.onSelect});

  /// 지금 탭.
  final KioskTab current;
  final ValueChanged<KioskTab> onSelect;

  /// 줄 높이(캔버스) — 1920x1080에서 약 123px. 누르는 자리는 탭 하나 전체(48 이상).
  static const double height = 60;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('kiosk-tab-bar'),
        height: height,
        decoration: BoxDecoration(
          color: KioskColors.surface,
          border: Border(top: BorderSide(color: KioskColors.border)),
        ),
        child: Row(children: [
          for (final tab in KioskTab.values)
            Expanded(child: _TabItem(tab: tab, selected: tab == current, onTap: () => onSelect(tab))),
        ]),
      );
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.tab, required this.selected, required this.onTap});

  final KioskTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? KioskColors.primary : KioskColors.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: '${kioskTabName(tab)} 탭',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('kiosk-tab-${tab.name}'),
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 56,
            height: 28,
            decoration: BoxDecoration(
              color: selected ? KioskColors.mint : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(_tabIcon(tab), size: 24, color: color),
          ),
          const SizedBox(height: 2),
          // 큰 글씨에서도 줄 높이 안에 들도록 글자만 칸에 맞춰 줄인다(잘리지 않게).
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(kioskTabName(tab),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: KioskType.caption,
                      height: 1.15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: color)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 탭 줄을 잠시 숨기게 하는 자리(누르기 확인·LG 가전 설정 확인·보내는 중) — 화면 안에서 확인 창이 뜬 동안 탭을 눌러
/// 그 화면을 벗어나지 않게(확인·승인이 앞선다). [KioskTabSuppressScope] 아래에 이 위젯이 하나라도 있으면 탭을 숨긴다.
class KioskTabBarSuppress extends StatefulWidget {
  const KioskTabBarSuppress({super.key});

  @override
  State<KioskTabBarSuppress> createState() => _KioskTabBarSuppressState();
}

class _KioskTabBarSuppressState extends State<KioskTabBarSuppress> {
  ValueNotifier<int>? _count;

  // 그리기 도중 다른 위젯을 다시 그리게 할 수 없다 — 셈은 그 프레임이 끝난 뒤 바꾼다.
  static void _later(VoidCallback f) {
    SchedulerBinding.instance.addPostFrameCallback((_) => f());
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_count != null) return;
    final count = KioskTabSuppressScope.maybeOf(context);
    if (count == null) return;
    _count = count;
    _later(() => count.value++);
  }

  @override
  void dispose() {
    final count = _count;
    if (count != null) _later(() => count.value--);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// [KioskTabBarSuppress]가 셈을 올리는 곳 — kiosk_screen이 화면 위에 하나 둔다.
class KioskTabSuppressScope extends InheritedWidget {
  const KioskTabSuppressScope({super.key, required this.count, required super.child});

  final ValueNotifier<int> count;

  static ValueNotifier<int>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KioskTabSuppressScope>()?.count;

  @override
  bool updateShouldNotify(KioskTabSuppressScope oldWidget) => oldWidget.count != count;
}
