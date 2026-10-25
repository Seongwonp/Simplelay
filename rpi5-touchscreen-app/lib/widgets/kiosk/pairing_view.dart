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


  int get _left => _deadline == null ? 0 : _deadline!.difference(DateTime.now()).inSeconds.clamp(0, 300);

  TextStyle _t(double size, {FontWeight weight = FontWeight.w500, Color? color}) =>
      TextStyle(fontSize: size, height: 1.3, fontWeight: weight, color: color ?? KioskColors.ink);

  // 연결 화면 짜임(10/25 실패널 사진 — 예전 글자 목록은 스크롤되며 주소가 아래로 잘리고 제목 밑으로 글이 겹쳤다):
  // 위 줄 제목 + 오른쪽 '닫기', 가운데는 스크롤 없이 한 화면(넘치면 통째로 조금 줄어든다).
  @override
  Widget build(BuildContext context) {
    final session = _session;
    final state = session?['state'];
    return ColoredBox(
        color: KioskColors.bg,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(KioskSpace.lg, KioskSpace.md, KioskSpace.lg, KioskSpace.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('휴대폰 연결하기', style: _t(KioskType.status, weight: FontWeight.w800))),
              OutlinedButton(
                  onPressed: _busy ? null : _close,
                  style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border),
                  child: Text('닫기', style: _t(KioskType.body, weight: FontWeight.w700))),
            ]),
            const SizedBox(height: KioskSpace.md),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth),
                      child: _body(session, state, box.maxHeight),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ));
  }

  Widget _body(Map<String, dynamic>? session, Object? state, double height) {
    if (session != null && state == 'open') return _openBody(session, height);
    if (state == 'pending') return _pendingBody(session!);
    final (icon, color, line) = switch (state) {
      'approved' => (Icons.check_circle_outline, KioskColors.success, '허락했어요. 휴대폰에서 연결됐는지 봐 주세요.'),
      'consumed' => (Icons.check_circle_outline, KioskColors.success, '휴대폰에 연결 정보를 보냈어요.'),
      'denied' => (Icons.block, KioskColors.muted, '이 휴대폰은 연결하지 않았어요.'),
      _ => (null, KioskColors.muted, null),
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) Icon(icon, size: 72, color: color),
      if (line != null) ...[
        const SizedBox(height: KioskSpace.sm),
        Text(line, textAlign: TextAlign.center, style: _t(KioskType.status, weight: FontWeight.w700)),
      ],
      if (_busy && session == null) const CircularProgressIndicator(),
      if (session != null && _deadline != null && state != 'consumed' && state != 'denied') ...[
        const SizedBox(height: KioskSpace.xs),
        Text('$_left초 남았어요', style: _t(KioskType.body, color: KioskColors.muted)),
      ],
      ..._errorLine(),
      if (state != 'approved' && state != 'consumed') ...[
        const SizedBox(height: KioskSpace.md),
        _newCodeButton(),
      ],
    ]);
  }

  // QR 왼쪽 · 할 일 세 줄과 숫자·주소 오른쪽.
  Widget _openBody(Map<String, dynamic> session, double height) {
    final qr = (height * 0.82).clamp(160.0, 340.0);
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: KioskSpace.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: KioskColors.primary, shape: BoxShape.circle),
              child: Text(n, style: _t(KioskType.caption, weight: FontWeight.w800, color: KioskColors.onAccent)),
            ),
            const SizedBox(width: KioskSpace.sm),
            Flexible(child: Text(text, style: _t(KioskType.body))),
          ]),
        );
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (session['qr_png'] case final String png) ...[
        Container(
          padding: const EdgeInsets.all(KioskSpace.sm),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
            border: Border.all(color: KioskColors.border, width: 2),
          ),
          child: Image.memory(base64Decode(png),
              width: qr, height: qr, gaplessPlayback: true, semanticLabel: '휴대폰 연결 QR 코드'),
        ),
        const SizedBox(width: KioskSpace.xl),
      ],
      // Flexible — QR 옆 남은 폭 안에서 줄을 바꾼다(10/26 실패널 점검: 할 일 글이 화면 오른쪽 끝에서 잘렸다).
      Flexible(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          step('1', '휴대폰을 본체와 같은 와이파이에 연결해 주세요.'),
          step('2', "SimpleLay 앱에서 '본체 연결하기'를 눌러 주세요."),
          step('3', 'QR 코드를 비추거나, 아래 숫자와 주소를 넣어 주세요.'),
          const SizedBox(height: KioskSpace.sm),
          Text('${session['code']}',
              key: const Key('pair-code'),
              style: _t(KioskType.key + 16, weight: FontWeight.w800).copyWith(letterSpacing: 6)),
          Text('주소 ${session['host']}', style: _t(KioskType.body, color: KioskColors.muted)),
          const SizedBox(height: KioskSpace.xs),
          Text('$_left초 남았어요', style: _t(KioskType.body, color: KioskColors.muted)),
          ..._errorLine(),
          const SizedBox(height: KioskSpace.md),
          _newCodeButton(),
        ]),
      )),
    ]);
  }

  // 폰 요청 — 이름과 맞춰 볼 글자를 크게, 허락·거절은 큰 단추 둘.
  Widget _pendingBody(Map<String, dynamic> session) {
    final mark = (session['request_id'] as String).substring(0, 6);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('이 휴대폰을 연결할까요?', style: _t(KioskType.status, weight: FontWeight.w800)),
      const SizedBox(height: KioskSpace.xs),
      Text('${session['phone']}', style: _t(KioskType.body, color: KioskColors.muted)),
      const SizedBox(height: KioskSpace.md),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: KioskSpace.xl, vertical: KioskSpace.md),
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
          border: Border.all(color: KioskColors.border, width: 2),
        ),
        child: Column(children: [
          Text('휴대폰 화면에도 이 글자가 보이는지 봐 주세요', style: _t(KioskType.body)),
          const SizedBox(height: KioskSpace.xs),
          Text(mark,
              key: const Key('pair-mark'),
              semanticsLabel: '휴대폰에도 $mark 표시가 있는지 봐 주세요',
              style: _t(KioskType.key + 8, weight: FontWeight.w800).copyWith(letterSpacing: 4)),
        ]),
      ),
      const SizedBox(height: KioskSpace.xs),
      Text('$_left초 남았어요', style: _t(KioskType.body, color: KioskColors.muted)),
      ..._errorLine(),
      const SizedBox(height: KioskSpace.md),
      Row(mainAxisSize: MainAxisSize.min, children: [
        OutlinedButton(
            onPressed: _busy ? null : () => _decide(false),
            style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border),
            child: Text('연결하지 않기', style: _t(KioskType.body, weight: FontWeight.w700))),
        const SizedBox(width: KioskSpace.md),
        ElevatedButton(
            onPressed: _busy ? null : () => _decide(true),
            style: KioskButtons.primary(background: KioskColors.primary, foreground: KioskColors.onAccent),
            child: Text('이 휴대폰 연결하기',
                style: _t(KioskType.body, weight: FontWeight.w800, color: KioskColors.onAccent))),
      ]),
    ]);
  }

  List<Widget> _errorLine() => [
        if (_error != null) ...[
          const SizedBox(height: KioskSpace.xs),
          Text(_error!, style: _t(KioskType.body, weight: FontWeight.w700, color: KioskColors.warning)),
        ],
      ];

  Widget _newCodeButton() => OutlinedButton(
      onPressed: _busy ? null : _open,
      style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border),
      child: Text('새 코드 받기', style: _t(KioskType.body, weight: FontWeight.w700)));
}
