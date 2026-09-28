import 'dart:async';
import 'package:flutter/material.dart';

typedef RoutineRequest = Future<Map<String, dynamic>> Function(
    Map<String, dynamic>? event);

/// This screen only calls simulator endpoints. It never dispatches real commands.
class RoutineRehearsalScreen extends StatefulWidget {
  const RoutineRehearsalScreen({super.key, required this.request});
  final RoutineRequest request;
  @override
  State<RoutineRehearsalScreen> createState() => _RoutineRehearsalScreenState();
}

class _RoutineRehearsalScreenState extends State<RoutineRehearsalScreen> {
  Map<String, dynamic>? _state;
  final Set<String> _selected = {};
  bool _busy = false, _online = false, _dirty = false;
  String? _error;
  Timer? _timer;
  int _epoch = 0;
  static const _phases = {
    'draft': '구성 선택',
    'review': '미리보기 · 재승인 대기',
    'running': '순서대로 모의 실행 중',
    'stopping': '정지 요청 · 확인 대기',
    'completed': '모의 실행 완료',
    'halted': '진행 중단',
    'unconfirmed': '동작 여부 확인 불가',
  };
  static const _results = {
    'not_started': '미실행',
    'excluded': '이번에는 제외',
    'running': '진행 중 · 결과 미확인',
    'succeeded': '모의 동작 성공',
    'failed': '모의 실패',
    'unconfirmed': '응답 유실 · 동작 여부 모름',
    'cancelled': '후속 실행 취소',
    'stopped': '모의 정지 확인',
  };
  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    super.dispose();
  }

  void _apply(Map<String, dynamic> value) {
    if (value['execution_mode'] != 'mock' || value['items'] is! List) {
      throw const FormatException('모의 응답이 아닙니다.');
    }
    final changed = _state?['session'] != value['session'] ||
        _state?['revision'] != value['revision'];
    if (changed) {
      _dirty = false;
      _selected.clear();
      for (final item in value['items'] as List) {
        if (item['selected'] == true) _selected.add(item['id'] as String);
      }
    }
    _state = value;
    _online = true;
    _error = null;
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final epoch = ++_epoch;
    try {
      final value = await widget.request(null);
      if (!mounted || epoch != _epoch) return;
      setState(() => _apply(value));
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _online = false;
        _error = '모의 서버 연결을 확인하세요. 마지막 결과는 최신이 아닐 수 있어요.';
      });
    }
  }

  Future<void> _send(String event) async {
    if (_busy || !_online || _state == null) return;
    final epoch = ++_epoch;
    final body = <String, dynamic>{
      'session': _state!['session'],
      'revision': _state!['revision'],
      'event': event,
      if (event == 'review') 'selected': _selected.toList(),
    };
    setState(() => _busy = true);
    try {
      final value = await widget.request(body);
      if (!mounted || epoch != _epoch) return;
      setState(() => _apply(value));
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _online = false;
        _error = '요청 결과를 확인하지 못했어요. 최신 상태를 다시 확인하세요. 자동 재전송하지 않습니다.';
      });
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _state?['phase'];
    final usable = _online && !_busy;
    final editable = usable && ['draft', 'review'].contains(phase);
    final active = usable && ['running', 'stopping'].contains(phase);
    final items = (_state?['items'] as List?) ?? [];
    Widget action(String event, String text, bool enabled) => Padding(
          padding: const EdgeInsets.all(4),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: enabled ? () => _send(event) : null,
            child: Text(text),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('저녁 휴식 · 다가전 모의')),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('모의 전용 · 합성 이력 · 실제 가전 연결 없음'),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!, semanticsLabel: _error),
          TextButton(
              onPressed: _busy ? null : _refresh,
              child: const Text('상태 다시 확인')),
          Text(_state?['reason'] as String? ?? '모의 시나리오를 불러오는 중이에요.'),
          for (final item in items)
            CheckboxListTile(
              title: Text(item['name'] as String),
              subtitle: Text(item['action'] as String),
              value: _selected.contains(item['id']),
              onChanged: editable
                  ? (value) => setState(() {
                        value == true
                            ? _selected.add(item['id'] as String)
                            : _selected.remove(item['id']);
                        _dirty = true;
                      })
                  : null,
            ),
          if (_dirty) const Text('구성이 바뀌었어요. 미리보기를 다시 확인하세요.'),
          if (phase == 'review' && !_dirty)
            Text(
                '확인할 구성: ${items.where((i) => i['selected'] == true).map((i) => '${i['name']} · ${i['action']}').join(' → ')}'),
          Wrap(children: [
            action('review', '선택한 구성 미리보기', editable && _selected.isNotEmpty),
            action('approve', '확인한 구성 승인 · 모의 실행',
                usable && phase == 'review' && !_dirty),
          ]),
          const Text('제외는 이번에만 적용돼요. 승인하지 않으면 실행하지 않아요.'),
          const Divider(height: 32),
          Text(_phases[phase] ?? '상태 확인 중',
              style: Theme.of(context).textTheme.headlineSmall),
          for (final item in items)
            ListTile(
              title:
                  Text('${item['name']}: ${_results[item['status']] ?? '미확인'}'),
              subtitle:
                  Text(item['receipt'] == 'unknown' ? '접수 여부 미확인' : '모의 결과'),
            ),
          action('stop', '전체 정지 요청', usable && phase == 'running'),
          const Text('요청은 정지 확인이 아닙니다. 이미 성공한 가전을 자동으로 되돌리지 않습니다.'),
          const Divider(height: 32),
          const Text('검증용 결과 주입 · 실제 센서 관측 아님'),
          Wrap(children: [
            action('success', '동작 성공 주입', active),
            action('failure', '실패 주입', active),
            action('link_lost', '응답 유실 주입', active),
            action('stop_confirmed', '정지 확인 주입', usable && phase == 'stopping'),
            action('reset', '새 모의 시나리오',
                usable && !['running', 'stopping'].contains(phase)),
          ]),
        ]),
      )),
    );
  }
}
