import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// 날씨 출처 한 줄 — 공공누리 제1유형(출처표시)의 표시 의무를 지키는 문장.
/// 키오스크의 날씨 안내도 같은 출처에서 온다.
const kWeatherSourceLine = '기상청 단기예보 조회서비스(공공데이터포털)';

/// 이용 허락 유형.
const kWeatherLicenseLine = '공공누리 제1유형(출처표시), 이용허락 제1유형';

/// 설정 → 앱 정보. 외부 자료의 출처와 이용 허락을 적는다.
class AppInfoScreen extends StatelessWidget {
  const AppInfoScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('앱 정보')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: [
            Text('SimpleLay', style: AppText.heading),
            const SizedBox(height: AppSpace.xs),
            Text('SimpleLay 본체와 함께 쓰는 폰 앱이에요. 본체의 작은 팔이 버튼식 가전을 대신 눌러요.',
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
