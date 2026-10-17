import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/appliance_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/input_guard.dart';
import '../widgets/panel_photo_view.dart' show applianceImageOverride;
import '../widgets/appliance_panel.dart';
import '../theme/app_tokens.dart';

/// 루틴 녹화 — 평소 누르는 순서대로 사진 속 버튼을 짚는다(UI 확정 §2).
///
/// **녹화 중에는 실제로 누르지 않는다.** 이 화면은 서버에 아무것도 보내지
/// 않고, '다음'을 누르면 짚은 순서(버튼 id)만 돌려준다. 저장은 편집기에서.
class RoutineRecordScreen extends ConsumerStatefulWidget {
  const RoutineRecordScreen({
    super.key,
    required this.applianceId,
    this.initial = const [],
  });

  final String applianceId;

  /// 다시 녹화할 때 이어 붙일 순서.
  final List<String> initial;

  @override
  ConsumerState<RoutineRecordScreen> createState() =>
      _RoutineRecordScreenState();
}

class _RoutineRecordScreenState extends ConsumerState<RoutineRecordScreen> {
  bool _accepted = false;
  late final List<String> _order = [...widget.initial];

  /// 서버 루틴 한 단계에 담을 수 있는 버튼 수(서버 MAX_BUTTONS_PER_RUN).
  static const _max = 20;

  @override
  Widget build(BuildContext context) {
    final appliance = ref
        .watch(installedAppliancesProvider)
        .where((a) => a.id == widget.applianceId)
        .firstOrNull;
    return InputGuard(dirty: !_accepted && _order.join("|") != widget.initial.join("|"), child: Scaffold(
      appBar: AppBar(title: const Text('누르는 순서 저장')),
      body: appliance == null
          ? Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Text('이 가전을 찾을 수 없어요.',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxl),
              children: [
                Text(
                  '평소 누르는 순서대로 버튼을 골라 주세요. 저장만 하고 누르지는 않아요.',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
                const SizedBox(height: AppSpace.md),
                AppliancePanel(
                  appliance: appliance,
                  imageOverride: applianceImageOverride,
                  pinned: _order,
                  onButton: (b) {
                    if (_order.length >= _max) return;
                    setState(() => _order.add(b.id));
                  },
                ),
                const SizedBox(height: AppSpace.lg),
                if (_order.isEmpty)
                  Text('아직 고른 버튼이 없어요',
                      style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
                else
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
                    children: [
                      for (var i = 0; i < _order.length; i++)
                        Chip(
                          key: Key('order-$i'),
                          avatar: CircleAvatar(
                            backgroundColor: context.appPrimary,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                  fontSize: AppFont.caption, color: context.appOnAccent),
                            ),
                          ),
                          label: Text(appliance.labelFor(_order[i])),
                        ),
                    ],
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.md),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _order.isEmpty
                      ? null
                      : () => setState(() => _order.removeLast()),
                  child: const Text('하나 지우기'),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: FilledButton(
                  onPressed: _order.isEmpty
                      ? null
                      : () async {
                          setState(() => _accepted = true);
                          await WidgetsBinding.instance.endOfFrame;
                          if (context.mounted) Navigator.of(context).pop(List<String>.of(_order));
                        },
                  child: const Text('다음'),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }
}
