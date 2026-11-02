import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';

/// 본체의 말 알아듣기가 받는 글자 수 상한과 같다.
const kVoiceTextMaxLength = 200;

/// '말로 하기' 화면의 글자 입력칸과 보내기 단추. 보낸 뒤 처리는 화면이 맡는다 — [onSubmit]에는 입력 그대로 넘긴다.
class VoiceTextInputBar extends StatelessWidget {
  const VoiceTextInputBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 보내는 중에는 입력은 두되 전송만 잠근다.
  final bool sending;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    // 큰 글씨에서 세 줄이면 키보드가 올라온 화면의 절반을 넘긴다.
    final maxLines = MediaQuery.textScalerOf(context).scale(1) >= 1.5 ? 2 : 3;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Semantics(
            label: '글자로 말하기',
            child: TextField(
              key: const Key('voice-text-field'),
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: maxLines,
              textInputAction: TextInputAction.send,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kVoiceTextMaxLength),
              ],
              decoration: const InputDecoration(
                hintText: '하고 싶은 말을 적어 주세요',
                hintMaxLines: 2,
              ),
              onSubmitted: onSubmit,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => IconButton.filled(
            key: const Key('voice-text-send'),
            tooltip: '보내기',
            constraints: const BoxConstraints.tightFor(width: 52, height: 52),
            onPressed: sending || value.text.trim().isEmpty
                ? null
                : () => onSubmit(controller.text),
            icon: const Icon(Icons.send_rounded, size: 24),
          ),
        ),
      ],
    );
  }
}
