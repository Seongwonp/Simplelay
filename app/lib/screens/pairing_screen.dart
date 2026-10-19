import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_tokens.dart';

final pairingApiFactoryProvider = Provider<RpiApiService Function(String)>(
    (_) => (host) => RpiApiService(host));

/// QR은 휴대폰 카메라의 링크 열기로도 들어온다. 숫자 코드 입력도 같은 흐름이다.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key, this.host, this.code});
  final String? host;
  final String? code;
  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  late final _host = TextEditingController(
      text: widget.host ??
          ref.read(rpiUrlProvider) ??
          'http://simplelay.local:8000');
  late final _code = TextEditingController(text: widget.code);
  final _phone = TextEditingController(text: '내 폰');
  RpiApiService? _api;
  String? _resolvedHost;
  Timer? _timer;
  DateTime? _deadline;
  String? _token;
  String? _requestId;
  String? _message;
  bool _busy = false;
  bool _polling = false;
  bool _connected = false;

  /// 주소·코드 칸을 펼쳤나. 처음에는 QR 찍기만 말한다 — 주소와 코드를 한꺼번에 물으면 처음 쓰는 사람이 무엇을 적을지
  /// 몰랐다(첫 사용 검토 10/19). 적은 값이 틀렸거나 주소로 닿지 않으면 칸을 펼쳐 무엇을 고칠지 보이게 한다.
  bool _manual = false;

  /// 본체 QR(휴대폰 카메라의 링크 열기)로 주소와 코드를 받았나.
  bool get _fromQr => (widget.code ?? '').isNotEmpty;

  @override
  void didUpdateWidget(PairingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy &&
        (widget.host != oldWidget.host || widget.code != oldWidget.code)) {
      _host.text = widget.host ?? _host.text;
      _code.text = widget.code ?? '';
      _connected = false;
      _message = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api?.dispose();
    _host.dispose();
    _code.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    var code = _code.text.trim();
    var host = _host.text.trim();
    if (code.startsWith('simplelay://')) {
      final qr = Uri.tryParse(code);
      if (qr == null || qr.host != 'pair') {
        setState(() {
          _manual = true;
          _message = '본체 화면의 QR 연결 주소를 봐 주세요.';
        });
        return;
      }
      code = qr.queryParameters['code'] ?? '';
      host = qr.queryParameters['host'] ?? '';
    }
    host = normalizeRpiUrl(host);
    final uri = Uri.tryParse(host);
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code) ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      setState(() {
        _manual = true;
        _message = '본체 주소와 여섯 자리 코드를 봐 주세요.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    _api?.dispose();
    try {
      var endpoint = host;
      if (uri.host.endsWith('.local')) {
        final ip = await ref.read(mdnsResolverProvider).resolveIPv4(uri.host);
        if (!mounted) return;
        if (ip != null) endpoint = uri.replace(host: ip).toString();
      }
      _resolvedHost = endpoint == host ? null : endpoint;
      final api = ref.read(pairingApiFactoryProvider)(endpoint);
      _api = api;
      final pending = await api.requestPairing(
          code, _phone.text.trim().isEmpty ? '내 폰' : _phone.text.trim());
      if (!mounted) return;
      final token = pending['token'];
      final requestId = pending['request_id'];
      final expires = pending['expires_in'];
      if (token is! String ||
          token.isEmpty ||
          requestId is! String ||
          requestId.length < 6 ||
          expires is! num ||
          expires <= 0 ||
          expires > 300) {
        throw StateError('invalid pairing response');
      }
      _host.text = host;
      _token = token;
      _requestId = requestId;
      _deadline = DateTime.now().add(Duration(seconds: expires.toInt()));
      setState(() => _message = '본체 화면에서 이 폰 연결을 허락해 주세요.');
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    } on RpiApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _manual = true;
          _message = '본체와 연결되지 않아요. 같은 와이파이인지, 주소가 맞는지 봐 주세요.';
        });
      }
    }
  }

  void _stopWaiting(String message) {
    _timer?.cancel();
    _token = null;
    if (mounted) {
      setState(() {
        _busy = false;
        _message = message;
      });
    }
  }

  Future<void> _poll() async {
    if (_polling || _token == null || !mounted) return;
    if (!DateTime.now().isBefore(_deadline!)) {
      _stopWaiting('연결 시간이 지났어요. 본체 화면에서 새 코드를 받아 주세요.');
      return;
    }
    setState(() {});
    _polling = true;
    try {
      final result = await _api!.pairingResult(_token!);
      if (!mounted) return;
      if (result['state'] == 'approved') {
        final key = result['api_key'] as String?;
        if (key == null || key.isEmpty) throw StateError('missing key');
        _timer?.cancel();
        // 저장값 로드가 늦게 도착해 새 연결을 덮지 않게 먼저 기다린다.
        await ref.read(rpiApiKeyProvider.notifier).ensureLoaded();
        await ref.read(rpiUrlProvider.notifier).ensureLoaded();
        if (!mounted) return;
        await ref.read(rpiApiKeyProvider.notifier).save(key);
        if (!mounted) return;
        await ref.read(rpiUrlProvider.notifier).save(_host.text);
        if (!mounted) return;
        if (_resolvedHost != null) {
          ref.read(resolvedRpiUrlProvider.notifier).state =
              (_host.text, _resolvedHost!);
        }
        await ref.read(rpiConnectionProvider.notifier).check();
        if (!mounted) return;
        final connected =
            ref.read(rpiConnectionProvider) == RpiConnectionState.connected;
        _stopWaiting(
            connected ? '본체와 연결했어요.' : '연결 허락은 저장했어요. 본체 연결을 다시 봐 주세요.');
        setState(() => _connected = true);
      } else if (result['state'] == 'denied') {
        _stopWaiting('본체에서 연결을 닫았어요. 새 코드를 받아 다시 연결해 주세요.');
      }
    } on RpiApiException catch (e) {
      if ([404, 410, 429].contains(e.statusCode)) _stopWaiting(e.message);
    } catch (_) {
      // 기한 안에서 재조회한다. 승인되지 않은 키는 저장하지 않는다.
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('폰 연결하기')),
        body: ListView(padding: const EdgeInsets.all(AppSpace.xl), children: [
          const Text('본체 화면에서 설정, 폰 연결하기를 열어 주세요.'),
          const SizedBox(height: AppSpace.sm),
          Text(
              _fromQr && !_manual
                  ? '본체의 QR을 읽었어요. 아래 "연결 요청하기"를 눌러 주세요.'
                  : '본체의 QR을 휴대폰 카메라로 찍어 주세요.',
              key: const Key('pair-lead'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpace.lg),
          TextField(
              controller: _phone,
              enabled: !_busy && !_connected,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '본체 화면에 보일 폰 이름')),
          if (!_manual && !_connected)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  key: const Key('pair-manual'),
                  onPressed: _busy ? null : () => setState(() => _manual = true),
                  child: const Text('QR을 찍을 수 없나요? 주소와 6자리 코드 입력')),
            ),
          if (_manual) ...[
            TextField(
                controller: _host,
                enabled: !_busy && !_connected,
                decoration: const InputDecoration(labelText: '본체 주소'),
                keyboardType: TextInputType.url),
            TextField(
                controller: _code,
                enabled: !_busy && !_connected,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '여섯 자리 코드')),
          ],
          if (_message != null) Text(_message!, key: const Key('pair-message')),
          if (_token != null) ...[
            Text('두 화면의 글자가 같은지 봐 주세요: ${_requestId!.substring(0, 6)}'),
            Text(
                '${_deadline!.difference(DateTime.now()).inSeconds.clamp(0, 300)}초 남았어요'),
          ],
          const SizedBox(height: AppSpace.lg),
          // QR이나 적은 코드가 없으면 보낼 것이 없다 — 누르면 보이지 않는 칸을 고치라고 했다.
          if (!_connected && (_fromQr || _manual))
            FilledButton(
                onPressed: _busy ? null : _connect,
                child: const Text('연결 요청하기')),
          if (_connected)
            FilledButton(
                onPressed: () {
                  // 첫 안내(온보딩)는 이 값으로 연결을 마쳤는지 안다.
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop(true);
                  } else {
                    context.go('/');
                  }
                },
                child: const Text('확인')),
        ]),
      );
}
