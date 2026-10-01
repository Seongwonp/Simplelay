import 'package:flutter/material.dart';

/// 저장 전 뒤로 가기(시스템·화면 버튼 모두)를 보호한다.
class InputGuard extends StatefulWidget {
  const InputGuard({super.key, required this.dirty, required this.child});
  final bool dirty;
  final Widget child;
  @override
  State<InputGuard> createState() => _InputGuardState();
}

class _InputGuardState extends State<InputGuard> {
  bool _leaving = false;
  bool _asking = false;
  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !widget.dirty || _leaving,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || _asking) return;
      _asking = true;
      final leave = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: const Text('입력한 내용을 남겨 두세요'),
        content: const Text('지금 나가면 저장하지 않은 내용을 잃어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('닫기')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('저장하지 않고 나가기')),
        ],
      ));
      _asking = false;
      if (leave != true || !mounted) return;
      setState(() => _leaving = true);
      await WidgetsBinding.instance.endOfFrame;
      if (context.mounted) Navigator.of(context).pop(result);
    },
    child: widget.child,
  );
}
