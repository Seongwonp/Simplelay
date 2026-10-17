part of '../settings_screen.dart';

// ── 설정 → 허브 ───────────────────────────────────────────────────────────
//
// 허브 연결 상태, 허브 위치("현재 위치로 설정"), 연결 주소·API 키, 예비
// 연결(BLE). 예전 설정의 '고급 설정'이 여기로 왔다.

class HubSettingsScreen extends ConsumerStatefulWidget {
  const HubSettingsScreen({super.key});

  @override
  ConsumerState<HubSettingsScreen> createState() => _HubSettingsScreenState();
}

class _HubSettingsScreenState extends ConsumerState<HubSettingsScreen> {
  // 화면이 저장된 설정을 기기에서 읽기 **전에** 열리면 provider가 아직 null이라
  // 칸이 빈다. 그 빈 칸을 그대로 저장하면 키가 지워졌다(2026-10-01 결함).
  // 그래서 ① 값이 늦게 올라오면 사용자가 손대지 않은 칸만 채우고 ② 저장은
  // 사용자가 실제로 고친 칸만 한다.
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  bool _urlEdited = false;
  bool _keyEdited = false;
  String _urlShown = '';
  String _keyShown = '';

  @override
  void initState() {
    super.initState();
    _showUrl(ref.read(rpiUrlProvider));
    _showKey(ref.read(rpiApiKeyProvider));
    _urlController.addListener(() {
      if (_urlController.text != _urlShown) _urlEdited = true;
    });
    _apiKeyController.addListener(() {
      if (_apiKeyController.text != _keyShown) _keyEdited = true;
    });
    ref.listenManual<String?>(rpiUrlProvider, (_, next) {
      if (!_urlEdited) _showUrl(next);
    });
    ref.listenManual<String?>(rpiApiKeyProvider, (_, next) {
      if (!_keyEdited) _showKey(next);
    });
  }

  void _showUrl(String? value) {
    _urlShown = value ?? '';
    _urlController.text = _urlShown;
  }

  void _showKey(String? value) {
    _keyShown = value ?? '';
    _apiKeyController.text = _keyShown;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('본체')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _RpiConnectionTile(),
            FilledButton.icon(onPressed: () => context.push('/pair'),
              icon: const Icon(Icons.qr_code), label: const Text('코드로 폰 연결하기')),
            const SizedBox(height: 24),
            _SectionHeader(title: '본체 위치'),
            const SizedBox(height: 8),
            const _HubLocationSection(),
            const SizedBox(height: 28),
            _SectionHeader(title: '연결 주소 (설치하는 분용)'),
            const SizedBox(height: 8),
            _AdvancedSection(
              controller: _urlController,
              apiKeyController: _apiKeyController,
              urlEdited: () => _urlEdited,
              apiKeyEdited: () => _keyEdited,
            ),
            const SizedBox(height: 24),
            _SectionHeader(title: '블루투스 연결 (설치하는 분용)'),
            const SizedBox(height: 4),
            _SavedDeviceSection(),
            const SizedBox(height: 12),
            _BleSection(),
            const SizedBox(height: 40),
          ],
        ),
      );
}

/// "현재 위치로 설정" — 폰 위치 권한 → `PUT /hub/location`.
///
/// 허브에는 GPS가 없다. 날씨 예보(5km 격자)용이라 **대략 위치**만 묻고,
/// 서버는 소수 둘째 자리(약 1km)로 줄여 저장한다. 거절해도 다른 기능은
/// 그대로다 -- 날씨 안내만 빠진다.
class _HubLocationSection extends ConsumerStatefulWidget {
  const _HubLocationSection();

  @override
  ConsumerState<_HubLocationSection> createState() =>
      _HubLocationSectionState();
}

class _HubLocationSectionState extends ConsumerState<_HubLocationSection> {
  bool _busy = false;
  String? _message;
  bool _warn = false;
  bool _offerSettings = false;

  void _say(String text, {bool warn = false, bool settings = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _warn = warn;
      _offerSettings = settings;
    });
  }

  Future<void> _setFromPhone() async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      _say('본체 주소를 먼저 넣어 주세요.', warn: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _offerSettings = false;
    });
    try {
      final outcome = await ref.read(locationServiceProvider).currentLocation();
      switch (outcome) {
        case LocationFix(:final lat, :final lon):
          try {
            await api.setHubLocation(lat, lon);
            ref.invalidate(hubLocationProvider);
            _say('본체 위치를 저장했어요. 약 1km 단위로만 저장해요.');
          } on RpiApiException catch (e) {
            _say(e.statusCode == 422 ? e.message : '저장하지 못했어요. 연결을 봐 주세요.',
                warn: true);
          } catch (_) {
            _say('저장하지 못했어요. 연결을 봐 주세요.', warn: true);
          }
        case LocationDenied():
          _say('위치 권한을 주지 않아서 정하지 않았어요. 다시 누르면 다시 물어봐요. '
              '위치가 없으면 날씨 안내만 빠지고 나머지는 그대로예요.',
              warn: true);
        case LocationDeniedForever():
          _say('위치 권한이 꺼져 있어요. 휴대폰 설정에서 이 앱의 위치 권한을 켜 주세요.',
              warn: true, settings: true);
        case LocationServiceOff():
          _say('휴대폰의 위치 기능이 꺼져 있어요. 켠 뒤 다시 눌러 주세요.', warn: true);
        case LocationFailed():
          _say('위치를 읽지 못했어요. 잠시 뒤 다시 해 주세요.', warn: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = ref.watch(hubLocationProvider);
    final line = location.when(
      loading: () => '확인하는 중이에요',
      error: (_, __) => '본체와 연결되면 볼 수 있어요',
      data: (l) => switch (l?.source) {
        'app' => '폰에서 정한 위치예요',
        'env' => '설치할 때 정한 위치예요',
        'none' => '아직 위치가 없어요. 날씨 안내를 하지 않아요',
        _ => '본체와 연결되면 볼 수 있어요',
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line, key: const Key('hub-location-line'),
            style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 4),
        Text('날씨를 받을 동네를 정해요. 본체는 위치를 몰라 폰 위치를 빌려요.',
            style: TextStyle(fontSize: 14, color: context.appMuted)),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('hub-location-set'),
          onPressed: _busy ? null : _setFromPhone,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location),
          label: const Text('현재 위치로 설정'),
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            key: const Key('hub-location-message'),
            style: TextStyle(
                fontSize: 15, color: _warn ? context.appWarning : null),
          ),
        ],
        if (_offerSettings)
          TextButton(
            onPressed: () => ref.read(locationServiceProvider).openSettings(),
            child: const Text('휴대폰 설정 열기'),
          ),
      ],
    );
  }
}
