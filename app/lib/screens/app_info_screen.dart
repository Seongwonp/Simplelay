import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/hub_provider.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// 날씨 출처 한 줄 — 공공누리 제1유형(출처표시)의 표시 의무를 지키는 문장.
/// 키오스크의 날씨 안내도 같은 출처에서 온다.
const kWeatherSourceLine = '기상청 단기예보 조회서비스(공공데이터포털)';

/// 이용 허락 유형.
const kWeatherLicenseLine = '공공누리 제1유형(출처표시), 이용허락 제1유형';

/// 설정 → 앱 정보. 외부 자료의 출처와 이용 허락을 적는다.
///
/// 'SimpleLay' 이름을 [kDeveloperUnlockTaps]번 누르면 설정 맨 아래 '개발자' 줄이 열린다(본체 개발자 모드일 때만,
/// 평가 17차 10/18 — 가족 화면에서 개발자 줄을 숨긴다).
class AppInfoScreen extends ConsumerStatefulWidget {
  const AppInfoScreen({super.key});

  @override
  ConsumerState<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends ConsumerState<AppInfoScreen> {
  int _taps = 0;

  void _onNameTap() {
    if (!ref.read(showDeveloperTabProvider) || ref.read(developerUnlockedProvider)) return;
    _taps++;
    if (_taps < kDeveloperUnlockTaps) return;
    ref.read(developerUnlockedProvider.notifier).state = true;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text("설정 맨 아래에 '개발자'가 생겼어요")));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('앱 정보')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: [
            GestureDetector(
              key: const Key('app-info-name'),
              behavior: HitTestBehavior.opaque,
              onTap: _onNameTap,
              child: Text('SimpleLay', style: AppText.heading),
            ),
            const SizedBox(height: AppSpace.xs),
            Text('SimpleLay 본체와 함께 쓰는 폰 앱이에요. 본체의 누름 장치가 버튼식 가전을 대신 눌러요.',
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            const SizedBox(height: AppSpace.xxxl),
            Text('날씨 출처', style: AppText.title),
            const SizedBox(height: AppSpace.sm),
            const Text(kWeatherSourceLine, style: TextStyle(fontSize: AppFont.caption)),
            const SizedBox(height: AppSpace.xs),
            Text(kWeatherLicenseLine,
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            const SizedBox(height: AppSpace.sm),
            Text(
              '날씨는 본체가 받아 본체 화면 안내에만 써요. 본체 위치는 약 1km 단위로만 저장해요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
        ),
      );
}
