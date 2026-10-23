import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';

class KioskPairingView extends StatefulWidget {
  const KioskPairingView({super.key, required this.api, required this.onClose});
  final KioskApiService api;
  final VoidCallback onClose;
  @override
  State<KioskPairingView> createState() => _KioskPairingViewState();
}

class _KioskPairingViewState extends State<KioskPairingView> {
  Map<String, dynamic>? _session;
  String? _error;
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  int _revision = 0;
  DateTime? _deadline;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    _revision++;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _session = null;
    });
    try {
      final session = await widget.api.pairingSession(create: true);
      if (!mounted) return;
      setState(() {
        _session = session;
        _deadline = DateTime.now()
            .add(Duration(seconds: (session['expires_in'] as num).toInt()));
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    } on KioskApiException catch (e) {
      if (mounted) setState(() => _error = e.detail);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '연결 코드를 받지 못했어요. 본체 연결을 보고 다시 눌러 주세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _poll() async {
    if (_polling || _busy || !mounted) return;
    if (_deadline != null && !DateTime.now().isBefore(_deadline!)) {
      _timer?.cancel();
      setState(() {
        _session = null;
        _error = "연결할 수 있는 시간이 지났어요. '새 코드 받기'를 눌러 주세요.";
      });
      return;
    }
    setState(() {});
    _polling = true;
    final revision = _revision;
    try {
      final session = await widget.api.pairingSession();
      if (mounted && revision == _revision) {
        setState(() => _session = {...?_session, ...session});
        // 허브가 키를 폰에 보냈다(consumed, 검토 10/19) — 이 화면의 일은 끝났다. 더 묻고 초를 세면 창이 끝날 때 '연결 시간이
        // 지났어요'로 바뀌어 이미 연결된 폰을 다시 연결하라는 말이 됐다. 폰은 창이 열린 동안 같은 키를 다시 받을 수 있다.
        if (session['state'] == 'consumed') _timer?.cancel();
      }
    } on KioskApiException catch (e) {
      if (e.statusCode == 410 && revision == _revision) {
        _timer?.cancel();
        if (mounted) {
          setState(() {
            _session = null;
            _error = e.detail;
          });
        }
      }
    } catch (_) {
      // 만료 시각은 서버를 다시 읽지 못해도 화면에서 계속 센다.
    } finally {
      _polling = false;
    }
  }

  Future<void> _decide(bool approved) async {
    final id = _session?['request_id'] as String?;
    if (id == null || _busy) return;
    _revision++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.approvePairing(id, approved);
      if (mounted) {
        setState(() => _session = {
              ..._session!,
              'state': approved ? 'approved' : 'denied'
            });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '연결 허락을 보내지 못했어요. 다시 눌러 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    _timer?.cancel();
    try {
      await widget.api.closePairing();
    } catch (_) {/* 창은 5분 뒤 만료된다. */}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final state = session?['state'];
    return ColoredBox(
        color: KioskColors.bg,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('휴대폰 연결하기',
                style: TextStyle(fontSize: KioskType.status, color: KioskColors.ink)),
            Expanded(
                child: SingleChildScrollView(
                    child: Column(children: [
              if (session != null && state == 'open') ...[
                const Text('같은 와이파이에 연결된 휴대폰 카메라로 이 QR 코드를 비춰 주세요.',
                    style: TextStyle(fontSize: KioskType.status)),
                if (session['qr_png'] case final String png)
                  Image.memory(base64Decode(png),
                      width: 190,
                      height: 190,
                      gaplessPlayback: true,
                      semanticLabel: '휴대폰 연결 QR 코드'),
                Text('${session['code']}',
                    key: const Key('pair-code'),
                    style: TextStyle(fontSize: KioskType.key, color: KioskColors.ink)),
                Text('주소 ${session['host']}',
                    style: const TextStyle(fontSize: KioskType.body)),
              ],
              if (state == 'pending') ...[
                const Text('이 휴대폰을 연결할까요?', style: TextStyle(fontSize: KioskType.status)),
                Text('${session!['phone']}',
                    style: const TextStyle(fontSize: KioskType.status)),
                Text(
                    '휴대폰에도 ${(session['request_id'] as String).substring(0, 6)} 표시가 있는지 봐 주세요',
                    style: const TextStyle(fontSize: KioskType.status)),
              ],
              if (state == 'approved')
                const Text('허락했어요. 휴대폰에서 연결됐는지 봐 주세요.',
                    style: TextStyle(fontSize: KioskType.status)),
              if (state == 'consumed')
                const Text('휴대폰에 연결 정보를 보냈어요.', style: TextStyle(fontSize: KioskType.status)),
              if (state == 'denied')
                const Text('이 휴대폰은 연결하지 않았어요.', style: TextStyle(fontSize: KioskType.status)),
              if (session != null && _deadline != null && state != 'consumed')
                Text(
                    '${_deadline!.difference(DateTime.now()).inSeconds.clamp(0, 300)}초 남았어요',
                    style: const TextStyle(fontSize: KioskType.status)),
              if (_error != null)
                Text(_error!,
                    style: TextStyle(
                        fontSize: KioskType.status, color: KioskColors.warning)),
            ]))),
            Wrap(alignment: WrapAlignment.end, spacing: 16, children: [
              TextButton(
                  onPressed: _busy ? null : _close, child: const Text('닫기')),
              if (state == 'pending') ...[
                OutlinedButton(
                    onPressed: _busy ? null : () => _decide(false),
                    child: const Text('연결하지 않기')),
                FilledButton(
                    onPressed: _busy ? null : () => _decide(true),
                    child: const Text('이 휴대폰 연결하기')),
              ] else
                FilledButton(
                    onPressed: _busy ? null : _open,
                    child: const Text('새 코드 받기')),
            ]),
          ]),
        ));
  }
}
