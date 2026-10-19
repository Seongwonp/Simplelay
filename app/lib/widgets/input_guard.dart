import 'package:flutter/material.dart';

/// 저장하지 않은 입력을 버리고 나갈지 묻는다. 나가면 true.
Future<bool> confirmDiscardInput(BuildContext context) async {
  final leave = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
    title: const Text('입력한 내용을 남겨 두세요'),
    content: const Text('지금 나가면 저장하지 않은 내용을 잃어요.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('닫기')),
      FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('저장하지 않고 나가기')),
    ],
  ));
  return leave == true;
}

/// 저장 전 뒤로 가기(시스템·화면 버튼 모두)를 보호한다.
///
/// [onBack]이 있으면 뒤로 가기가 화면을 닫지 않고 그것을 부른다 — 여러 단계 화면에서 한 단계 앞으로
/// (실화면 10/19: 가전 추가 2단계에서 시스템 뒤로 가기가 등록 전체를 닫으려 했다).
class InputGuard extends StatefulWidget {
  const InputGuard({super.key, required this.dirty, required this.child, this.onBack});
  final bool dirty;
  final Widget child;
  final VoidCallback? onBack;
  @override
  State<InputGuard> createState() => _InputGuardState();
}

class _InputGuardState extends State<InputGuard> {
  bool _leaving = false;
  bool _asking = false;
  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: widget.onBack == null && (!widget.dirty || _leaving),
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || _asking) return;
      final back = widget.onBack;
      if (back != null) {
        back();
        return;
      }
      _asking = true;
      final leave = await confirmDiscardInput(context);
      _asking = false;
      if (!leave || !mounted) return;
      setState(() => _leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (context.mounted) Navigator.of(context).pop(result);
    },
    child: widget.child,
  );
}
