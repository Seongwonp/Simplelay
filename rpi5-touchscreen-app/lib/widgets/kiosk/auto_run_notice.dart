import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../theme/kiosk_colors.dart';

/// 자동 실행 결과 한 줄(2026-10-14). 화면 위에 줄을 **더하는** 띠라 아래 화면을 덮지 않는다 — 비상정지 띠와 같은 자리
/// 규칙. 실행·동작 중(정지 버튼이 있는 화면)에는 키오스크가 그리지 않는다.
class KioskAutoRunNotice extends StatelessWidget {
  const KioskAutoRunNotice({super.key, required this.text, this.onClose});

  final String text;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        label: '자동으로 하기. $text',
        child: ExcludeSemantics(
          child: Container(
            key: const ValueKey('auto-run-notice'),
            color: KioskColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.autorenew, size: 22, color: KioskColors.muted),
                const SizedBox(width: 8),
                const Text('자동으로 하기',
                    style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: KioskType.body, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ),
                if (onClose != null)
                  TextButton(onPressed: onClose, child: const Text('닫기')),
              ],
            ),
          ),
        ),
      );
}
