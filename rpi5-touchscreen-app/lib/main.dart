import 'package:flutter/material.dart';

import 'screens/kiosk_screen.dart';
import 'services/kiosk_settings_store.dart';
import 'theme/kiosk_colors.dart';

void main() => runApp(const SimpleLayKioskApp());

class SimpleLayKioskApp extends StatelessWidget {
  const SimpleLayKioskApp({super.key});

  // 설정 영속화는 프로덕션에서만 — 테스트는 미주입(세션 한정)으로
  // 실제 홈 디렉터리 파일을 건드리지 않는다
  @override
  Widget build(BuildContext context) => KioskThemedApp(home: KioskScreen(settings: KioskSettingsStore()));
}

/// 키오스크 앱 껍데기 — 앱 테마를 지금 색 한 벌에서 만들고, 색 한 벌이 바뀌면(어두운 화면·고대비·조용한 시간 어둡게) 다시 만든다.
/// 대화 창·알림 줄은 키오스크 화면 바깥(앱 Navigator)에서 그려져 앱 테마를 쓴다 — 예전에는 시작할 때 한 번만 읽어 대화 창이
/// 어두운 화면·고대비를 따르지 않았다(코드 검토 10/24).
class KioskThemedApp extends StatefulWidget {
  const KioskThemedApp({super.key, required this.home});

  final Widget home;

  @override
  State<KioskThemedApp> createState() => _KioskThemedAppState();
}

class _KioskThemedAppState extends State<KioskThemedApp> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    KioskColors.listenable.addListener(_onPalette);
  }

  @override
  void dispose() {
    KioskColors.listenable.removeListener(_onPalette);
    super.dispose();
  }

  // 색은 그리는 도중(키오스크 화면 build·dispose)에도 바뀐다 — 그 자리에서 다시 그리지 않고 다음 프레임에.
  void _onPalette() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SimpleLay',
        debugShowCheckedModeBanner: false,
        theme: KioskColors.theme(),
        home: widget.home,
      );
}
