import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 조작할 가전이 아직 없을 때 보여주는 안내.
///
/// "설치한 가전 0대"는 예외가 아니라 **정상 제품 상태**다 -- 처음 설치한
/// 사람은 반드시 여기를 지난다. 그래서 오류처럼 붉게 칠하지 않고, 빈 화면이나
/// 비활성 버튼만 두지도 않는다. 무엇이 없고 무엇을 하면 되는지 말하고,
/// 거기로 가는 길을 같이 둔다.
class NoApplianceNotice extends StatelessWidget {
  const NoApplianceNotice({
    super.key,
    required this.title,
    required this.body,
    required this.onAdd,
  });

  /// 이 화면에서 못 하게 된 일을 가리키는 한 줄.
  final String title;

  /// 왜 그런지와 무엇을 하면 되는지.
  final String body;

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_home_outlined, size: 52, color: context.appMuted),
              const SizedBox(height: 18),
              Text(title, textAlign: TextAlign.center, style: AppText.title),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: context.appMuted),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('홈에서 가전 추가하기'),
              ),
            ],
          ),
        ),
      );
}
