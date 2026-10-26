import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../theme/kiosk_colors.dart';

/// 자동 실행 결과 한 줄(2026-10-14). 화면 위에 줄을 **더하는** 띠라 아래 화면을 덮지 않는다 — 비상정지 띠와 같은 자리
/// 규칙. 실행·동작 중(정지 버튼이 있는 화면)에는 키오스크가 그리지 않는다.
///
/// 되돌리기(2026-10-26, 맡기기 신뢰 강화): [onUndo]와 [undoFor]가 있으면 그 시간 동안만 '되돌리기'를 보인다(본체가 잰 남은
/// 시간 — 5분 안). 누르는 동안은 다시 누를 수 없다. 시간이 지나면 단추가 저절로 사라진다.
class KioskAutoRunNotice extends StatefulWidget {
  const KioskAutoRunNotice({super.key, required this.text, this.onClose, this.onUndo, this.undoFor});

  final String text;
  final VoidCallback? onClose;
  final Future<void> Function()? onUndo;
  final Duration? undoFor;

  static const String kUndoLabel = '되돌리기';

  @override
  State<KioskAutoRunNotice> createState() => _KioskAutoRunNoticeState();
}

class _KioskAutoRunNoticeState extends State<KioskAutoRunNotice> {
  Timer? _undoTimer;
  bool _undoOpen = false;
  bool _undoBusy = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(KioskAutoRunNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.undoFor != widget.undoFor || (oldWidget.onUndo == null) != (widget.onUndo == null)) _arm();
  }

  void _arm() {
    _undoTimer?.cancel();
    final left = widget.undoFor;
    _undoOpen = widget.onUndo != null && left != null && left > Duration.zero;
    if (_undoOpen) {
      _undoTimer = Timer(left!, () {
        if (mounted) setState(() => _undoOpen = false);
      });
    }
  }

  @override
  void dispose() {
    _undoTimer?.cancel();
    super.dispose();
  }

  Future<void> _undo() async {
    final onUndo = widget.onUndo;
    if (onUndo == null || _undoBusy) return;
    setState(() => _undoBusy = true);
    try {
      await onUndo();
    } finally {
      if (mounted) setState(() => _undoBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('auto-run-notice'),
        color: KioskColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                container: true,
                label: '자동 실행. ${widget.text}',
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      Icon(Icons.autorenew, size: 22, color: KioskColors.muted),
                      const SizedBox(width: 8),
                      Text('자동 실행', style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: KioskType.body, fontWeight: FontWeight.w600, color: KioskColors.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_undoOpen)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: OutlinedButton(
                  key: const ValueKey('auto-run-undo'),
                  onPressed: _undoBusy ? null : _undo,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                  child: const Text(KioskAutoRunNotice.kUndoLabel),
                ),
              ),
            if (widget.onClose != null) TextButton(onPressed: widget.onClose, child: const Text('닫기')),
          ],
        ),
      );
}
