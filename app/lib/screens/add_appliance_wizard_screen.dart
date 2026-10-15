import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/hub.dart';
import '../providers/appliance_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../widgets/panel_photo_view.dart';
import '../widgets/input_guard.dart';
import '../widgets/appliance_setup_card.dart';
import 'appliance_editor_screen.dart';

/// 가전 추가 5단계(UI 확정 §2, 실행 계획 §3-2):
/// ① 사진 ② 프레임 모서리 4점 ③ 버튼 짚고 이름 붙이기 ④ 정지 버튼과 쉬는 자리
/// ⑤ 확인 주행.
///
/// **사진 파일은 서버로 보내지 않는다.** 사진 크기와 짚은 좌표(px)만 보내고,
/// 사진 → mm 계산은 서버(`PUT /appliances/{id}/mapping`)가 한다. 거절 사유(422)는
/// 서버가 쓴 문장을 그대로 보여 준다. 확인 주행은 누르지 않고 버튼 위를
/// 지나가기만 하며, 모의 주행이면 그렇다고 말한다.
class AddApplianceWizardScreen extends ConsumerStatefulWidget {
  const AddApplianceWizardScreen({super.key, this.initial, this.verifyOnly = false});
  final ApplianceMap? initial;
  final bool verifyOnly;

  @override
  ConsumerState<AddApplianceWizardScreen> createState() =>
      _AddApplianceWizardScreenState();
}

/// 짚은 버튼 하나.
class _Tapped {
  _Tapped(this.id, this.label, this.point);
  final String id;
  String label;
  final PhotoPoint point;
}

const _stepTitles = [
  '조작부 사진',
  '기계 틀 네 귀퉁이 짚기',
  '버튼 짚고 이름 붙이기',
  '정지 버튼과 쉬는 자리',
  '확인 주행',
];

const _cornerNames = ['왼쪽 위', '오른쪽 위', '오른쪽 아래', '왼쪽 아래'];

class _AddApplianceWizardScreenState
    extends ConsumerState<AddApplianceWizardScreen> {
  int _step = 0;

  // ① 사진
  File? _photo;
  Size? _photoSize;
  final _name = TextEditingController(text: '전자레인지');
  final _room = TextEditingController();
  ApplianceCategory _category = ApplianceCategory.microwave;

  // ② 모서리
  final List<PhotoPoint> _corners = [];
  MappingFrame? _frame;
  bool _frameLoaded = false;
  final _frameW = TextEditingController();
  final _frameH = TextEditingController();

  // ③ 버튼
  final List<_Tapped> _buttons = [];
  int _buttonSeq = 1;

  // ④ 정지·쉬는 자리
  String? _stopId;
  int _stopPresses = 1;
  PhotoPoint? _park;
  bool _placingPark = false;

  // ⑤ 저장·확인 주행
  bool _busy = false;
  String? _error;
  ApplianceMap? _saved;
  MappingSaveResult? _mapping;
  VerifyPass? _pass;
  Timer? _poll;

  /// 이 등록의 가전 id. 저장을 다시 시도해도 같은 가전을 가리키게 한 번만 만든다.
  late final String _id = widget.initial?.id ?? 'custom_${DateTime.now().millisecondsSinceEpoch}';
  bool _transferring = false;
  bool _stopChosen = false;

  @override
  void initState() {
    super.initState();
    final a = widget.initial;
    if (a != null) {
      _name.text = a.name;
      _room.text = a.location ?? '';
      _category = a.category;
      _photo = a.photoPath == null ? null : File(a.photoPath!);
      _stopId = a.stopButton;
      _stopChosen = a.stopButton != null;
      final mapping = a.panelMapping;
      if (mapping != null) {
        _photoSize = Size(mapping.photoWidth, mapping.photoHeight);
        _corners.addAll(mapping.corners);
        for (final b in a.buttons) {
          final point = mapping.buttons[b.id];
          if (point != null) _buttons.add(_Tapped(b.id, b.label, point));
        }
        _park = mapping.parkPoint;
        _step = widget.verifyOnly ? 4 : 1;
        if (widget.verifyOnly) _saved = a;
        unawaited(_loadFrame());
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _name.dispose();
    _room.dispose();
    _frameW.dispose();
    _frameH.dispose();
    super.dispose();
  }

  // ── 단계 이동 ─────────────────────────────────────────────────────────

  bool get _canNext => switch (_step) {
        0 => _photo != null &&
            _photoSize != null &&
            _name.text.trim().isNotEmpty,
        1 => _corners.length == 4 && _frameReady,
        2 => _buttons.isNotEmpty,
        3 => !_busy,
        _ => false,
      };

  bool get _frameReady =>
      (_frame?.known ?? false) || (_parsedFrameW != null && _parsedFrameH != null);

  double? get _parsedFrameW => _positive(_frameW.text);
  double? get _parsedFrameH => _positive(_frameH.text);

  static double? _positive(String raw) {
    final v = double.tryParse(raw.trim());
    return (v == null || v <= 0 || v > 2000) ? null : v;
  }

  Future<void> _next() async {
    if (_step == 3) {
      await _saveMapping();
      return;
    }
    setState(() {
      _step++;
      if (_step == 3 && !_stopChosen) {
        final candidates = _buttons.where((b) => RegExp(r'정지|취소|stop|cancel', caseSensitive: false).hasMatch(b.label)).toList();
        _stopId = candidates.length == 1 ? candidates.single.id : null;
      }
      _error = null;
    });
    if (_step == 1 && !_frameLoaded) unawaited(_loadFrame());
  }

  void _back() {
    if (_step == 0) return;
    setState(() {
      _step--;
      _error = null;
      _placingPark = false;
    });
  }

  // ── ① 사진 ────────────────────────────────────────────────────────────

  Future<void> _takePhoto() async {
    final service = ref.read(photoServiceProvider);
    final photo = await service.takePhoto();
    if (photo == null || !mounted) return;
    final size = await service.imageSize(photo);
    if (!mounted) return;
    if (size == null) {
      setState(() => _error = '사진을 읽지 못했어요. 다시 찍어 주세요.');
      return;
    }
    setState(() {
      _photo = photo;
      _photoSize = size;
      _error = null;
      // 사진이 바뀌면 짚은 자리는 모두 무효다.
      _corners.clear();
      _buttons.clear();
      _stopId = null;
      _park = null;
    });
  }

  // ── ② 모서리 ──────────────────────────────────────────────────────────

  Future<void> _loadFrame() async {
    final api = ref.read(rpiApiServiceProvider);
    MappingFrame? frame;
    if (api != null) {
      try {
        frame = await api.mappingFrame();
      } catch (_) {
        frame = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _frame = frame;
      _frameLoaded = true;
    });
  }

  // ── ③ 버튼 ────────────────────────────────────────────────────────────

  Future<void> _addButton(PhotoPoint p) async {
    final existing = widget.initial;
    if (existing != null) {
      final chosen = await showDialog<ApplianceButton>(context: context, builder: (dialog) => SimpleDialog(
        title: const Text('이 자리에 있는 버튼을 골라 주세요'),
        children: [for (final b in existing.buttons.where((b) => !_buttons.any((t) => t.id == b.id)))
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog, b), child: Text(b.label)),
        ],
      ));
      if (chosen != null && mounted) setState(() => _buttons.add(_Tapped(chosen.id, chosen.label, p)));
      return;
    }
    final suggested = '버튼 ${_buttons.length + 1}';
    final label = await _askName(suggested);
    if (label == null || !mounted) return;
    setState(() {
      _buttons.add(_Tapped('B${(_buttonSeq++).toString().padLeft(2, '0')}',
          _unique(label), p));
    });
  }

  Future<void> _rename(_Tapped b) async {
    if (widget.initial != null) return;
    final label = await _askName(b.label);
    if (label == null || !mounted) return;
    setState(() => b.label = _unique(label, except: b));
  }

  /// 버튼 이름은 가전 안에서 겹치지 않아야 한다 -- 실행 명령이 이름으로 간다.
  String _unique(String label, {_Tapped? except}) {
    final taken = {
      for (final b in _buttons)
        if (!identical(b, except)) b.label,
    };
    if (!taken.contains(label)) return label;
    var n = 2;
    while (taken.contains('$label $n')) {
      n++;
    }
    return '$label $n';
  }

  Future<String?> _askName(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('버튼 이름'),
        content: TextField(
          key: const Key('wizard-button-name'),
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '예: 시작, 30초, 문열림'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('취소')),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              Navigator.pop(dialog, v.isEmpty ? null : v);
            },
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  // ── ④ 저장 ────────────────────────────────────────────────────────────

  Future<void> _saveMapping() async {
    final api = ref.read(rpiApiServiceProvider);
    final size = _photoSize;
    if (api == null || size == null) {
      setState(() => _error = '허브에 연결되면 저장할 수 있어요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await _draftAppliance();
      // 1) 가전과 버튼 이름을 허브에 올린다 -- 매핑은 허브가 아는 버튼에만 붙는다.
      if (widget.initial == null) await api.registerApplianceStrict(draft);
      // 2) 사진 좌표 → mm. 거절(422)은 서버 문장 그대로.
      final result = await api.saveMapping(
        _id,
        MappingRequest(
          photoWidth: size.width.round(),
          photoHeight: size.height.round(),
          corners: _corners,
          buttons: {for (final b in _buttons) b.id: b.point},
          frameWidthMm: (_frame?.known ?? false) ? null : _parsedFrameW,
          frameHeightMm: (_frame?.known ?? false) ? null : _parsedFrameH,
          stopButton: _stopId,
          stopPresses: _stopPresses,
          parkPoint: _park,
        ),
      );
      // 3) 이 폰에 남긴다. 서버가 돌려준 정의(판 번호·사진 매핑)에 이 폰의
      //    사진 경로와 방 이름을 얹는다. 대기열로 다시 올리지 않는다 -- 같은
      //    정의를 또 올리면 방금 계산한 mm 좌표를 덮을 수 있다.
      final server = result.appliance;
      final local = server == null
          ? draft
          : _withLocal(ApplianceMap.fromJson(server), draft);
      final notifier = ref.read(customAppliancesProvider.notifier);
      if (ref.read(customAppliancesProvider).any((a) => a.id == _id)) {
        await notifier.replace(local);
      } else {
        await notifier.add(local);
      }
      await ref.read(selectedApplianceProvider.notifier).select(local);
      if (!mounted) return;
      setState(() {
        _saved = local;
        _mapping = result;
        _step = 4;
      });
    } on RpiApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.statusCode == 0 || e.message.isEmpty
            ? '저장하지 못했어요. 연결을 확인해 주세요.'
            : e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '저장하지 못했어요. 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ApplianceMap _withLocal(ApplianceMap server, ApplianceMap draft) =>
      ApplianceMap(
        id: server.id,
        name: server.name,
        location: draft.location,
        category: server.category,
        rows: server.rows,
        cols: server.cols,
        buttons: server.buttons,
        isCustom: true,
        photoPath: draft.photoPath,
        revision: server.revision,
        controlPath: server.controlPath,
        panelMapping: server.panelMapping ??
            PanelMapping(
              photoWidth: _photoSize!.width,
              photoHeight: _photoSize!.height,
              corners: List.of(_corners),
              buttons: {for (final b in _buttons) b.id: b.point},
              parkPoint: _park,
            ),
        stopButton: server.stopButton ?? _stopId,
      );

  /// 짚은 자리로 버튼판(행·열)을 만든다. 키오스크·버튼판 화면은 아직 격자로
  /// 그리므로, 사진 위 위치를 줄(세로) → 칸(가로) 순서로 옮겨 적는다.
  Future<ApplianceMap> _draftAppliance() async {
    final photoPath = await _persistPhoto();
    if (widget.initial case final a?) {
      return ApplianceMap.fromJson({...a.toJson(), 'photo_path': photoPath});
    }
    final grid = gridFromPoints(
      [for (final b in _buttons) (b.id, b.label, b.point)],
      rowTolerance: (_photoSize?.height ?? 1000) * 0.06,
    );
    final room = _room.text.trim();
    return ApplianceMap(
      id: _id,
      name: _name.text.trim(),
      location: room.isEmpty ? null : room,
      category: _category,
      rows: grid.rows,
      cols: grid.cols,
      buttons: grid.buttons,
      isCustom: true,
      photoPath: photoPath,
    );
  }

  /// 사진은 image_picker 임시 캐시에 있다 -- 문서 폴더로 복사한 경로만 남긴다.
  /// 복사 실패는 등록을 막지 않는다(사진 없이 자리만 남는다).
  Future<String?> _persistPhoto() async {
    final photo = _photo;
    if (photo == null) return null;
    return ref.read(photoServiceProvider).persist(photo, _id);
  }

  // ── ⑤ 확인 주행 ───────────────────────────────────────────────────────

  Future<void> _startPass() async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pass = await api.startVerifyPass(_id);
      if (!mounted) return;
      setState(() => _pass = pass);
      _poll?.cancel();
      var ticks = 0;
      _poll = Timer.periodic(const Duration(milliseconds: 800), (t) async {
        ticks++;
        // 2분이 넘으면 더 기다리지 않는다 -- 상태를 모른다고 말한다.
        if (ticks > 150) {
          t.cancel();
          if (mounted) setState(() => _error = '확인 주행 결과를 받지 못했어요. 허브 화면을 확인해 주세요.');
          return;
        }
        try {
          final next = await api.verifyPassStatus(_id);
          if (!mounted) return;
          setState(() => _pass = next);
          if (!next.running) t.cancel();
        } catch (_) {
          // 일시적 통신 오류는 다음 주기에 다시 묻는다.
        }
      });
    } on RpiApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '확인 주행을 시작하지 못했어요. 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish() {
    _poll?.cancel();
    ref.invalidate(setupPassProvider(_id));
    final saved = _saved;
    if (saved == null) {
      context.pop();
      return;
    }
    context.go('/');
  }

  // ── 화면 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return InputGuard(
      dirty: !_transferring && _saved == null && (_photo != null || _room.text.isNotEmpty || _name.text != '전자레인지' || _buttons.isNotEmpty),
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '닫기',
          icon: const Icon(Icons.close),
          // context.pop()은 PopScope를 거치지 않아 입력 보호를 건너뛴다 —
          // maybePop으로 InputGuard의 확인 대화를 거친다.
          onPressed: _step == 4 ? _finish : () => Navigator.of(context).maybePop(),
        ),
        title: const Text('가전 추가'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          _Stepper(step: _step),
          const SizedBox(height: 12),
          Text('${_step + 1}. ${_stepTitles[_step]}',
              key: const Key('wizard-step-title'),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ...switch (_step) {
            0 => _photoStep(),
            1 => _cornerStep(),
            2 => _buttonStep(),
            3 => _stopStep(),
            _ => _passStep(),
          },
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('wizard-error'),
                style: TextStyle(fontSize: 15, color: context.appDanger)),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: _step == 4
              ? FilledButton(
                  key: const Key('wizard-finish'),
                  onPressed: (_pass?.running ?? false) ? null : _finish,
                  child: Text(_pass == null ? '확인 주행 없이 끝내기' : '끝내기'),
                )
              : Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('wizard-back'),
                        onPressed: _step == 0 || _busy ? null : _back,
                        child: const Text('이전'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: const Key('wizard-next'),
                        onPressed: _canNext ? _next : null,
                        child: Text(_step == 3 ? '저장하고 다음' : '다음'),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
    );
  }

  Widget _photoPanel({
    List<PanelMark> marks = const [],
    void Function(PhotoPoint)? onTap,
    required String label,
  }) {
    final size = _photoSize!;
    return PanelPhotoView(
      key: const Key('wizard-photo'),
      photoWidth: size.width,
      photoHeight: size.height,
      photoPath: _photo?.path,
      image: applianceImageOverride,
      marks: marks,
      onTapPhoto: onTap,
      semanticsLabel: label,
    );
  }

  List<Widget> _hint(String text) => [
        Text(text, style: TextStyle(fontSize: 15, color: context.appMuted)),
        const SizedBox(height: 12),
      ];

  List<Widget> _photoStep() => [
        ..._hint('기계 틀이 다 보이게 찍어 주세요.'),
        // 개인정보 안내는 작은 글씨 한 줄로(2026-10-14 UX).
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('사진은 이 폰에만 남고 허브에는 짚은 자리만 보내요.',
              style: TextStyle(fontSize: 13, color: context.appMuted)),
        ),
        if (_photo == null || _photoSize == null)
          Container(
            height: 180,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.appSurfaceLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.appBorderSubtle),
            ),
            child: FilledButton.icon(
              key: const Key('wizard-take-photo'),
              onPressed: _takePhoto,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('사진 찍기'),
            ),
          )
        else ...[
          _photoPanel(label: '찍은 조작부 사진'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _takePhoto,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 찍기'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('wizard-name'),
          controller: _name,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '가전 이름 (예: 전자레인지)'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          controller: _room,
          onChanged: (_) => setState(() {}),
          maxLength: 20,
          decoration: const InputDecoration(labelText: '방 (선택, 예: 주방)'),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in ApplianceCategory.values)
              ChoiceChip(
                avatar: Icon(c.icon, size: 18),
                label: Text(c.label),
                selected: _category == c,
                onSelected: (_) => setState(() {
                  if (_name.text.isEmpty || _name.text == _category.label) _name.text = c.label;
                  _category = c;
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: widget.initial != null ? null : () async {
              setState(() => _transferring = true);
              await WidgetsBinding.instance.endOfFrame;
              if (!mounted) return;
              if (context.mounted) {
                context.pushReplacement('/appliance/new', extra: ApplianceDraft(
                    name: _name.text, room: _room.text, category: _category));
              }
            },
            child: const Text('사진 없이 버튼판으로 등록하기'),
          ),
        ),
      ];

  List<Widget> _cornerStep() {
    final nextCorner = _corners.length < 4 ? _cornerNames[_corners.length] : null;
    return [
      ..._hint(nextCorner == null
          ? '네 귀퉁이를 모두 짚었어요. 틀렸으면 "다시 짚기"를 눌러 주세요.'
          : '사진에서 기계 틀 귀퉁이를 왼쪽 위부터 차례로 눌러 주세요. 지금: $nextCorner'),
      _photoPanel(
        label: '기계 틀 귀퉁이를 짚는 사진',
        marks: [
          for (var i = 0; i < _corners.length; i++)
            PanelMark(
              id: 'corner-$i',
              kind: PanelMarkKind.corner,
              point: _corners[i],
              number: i + 1,
            ),
        ],
        onTap: _corners.length >= 4
            ? null
            : (p) => setState(() => _corners.add(p)),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _corners.isEmpty ? null : () => setState(_corners.clear),
          icon: const Icon(Icons.undo),
          label: const Text('다시 짚기'),
        ),
      ),
      if (!_frameLoaded)
        const LinearProgressIndicator()
      else if (_frame?.known ?? false)
        Text(
          '기계 틀 크기: 가로 ${_frame!.widthMm!.toStringAsFixed(0)}mm · 세로 ${_frame!.heightMm!.toStringAsFixed(0)}mm',
          style: TextStyle(fontSize: 14, color: context.appMuted),
        )
      else ...[
        Text('기계 틀 크기를 아직 몰라요. 자로 잰 안쪽 크기를 적어 주세요.',
            style: TextStyle(fontSize: 14, color: context.appWarning)),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('wizard-frame-w'),
                controller: _frameW,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '가로 (mm)'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const Key('wizard-frame-h'),
                controller: _frameH,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '세로 (mm)'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _buttonStep() => [
        ..._hint('사진 속 버튼을 누르고 이름을 붙여요.'),
        _photoPanel(
          label: '버튼을 짚는 사진, ${_buttons.length}개 지정',
          marks: [
            for (final b in _buttons)
              PanelMark(
                id: b.id,
                kind: PanelMarkKind.button,
                point: b.point,
                label: b.label,
              ),
          ],
          onTap: _buttons.length >= 60 ? null : _addButton,
        ),
        const SizedBox(height: 10),
        if (_buttons.isEmpty)
          Text('아직 짚은 버튼이 없어요',
              style: TextStyle(fontSize: 15, color: context.appMuted))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in _buttons)
                InputChip(
                  key: Key('wizard-chip-${b.id}'),
                  label: Text(b.label),
                  tooltip: '이름 바꾸기',
                  onPressed: () => _rename(b),
                  onDeleted: () => setState(() {
                    _buttons.remove(b);
                    if (_stopId == b.id) _stopId = null;
                  }),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Text('다음: 4. 정지 버튼과 쉬는 자리 · 5. 확인 주행(허브가 버튼 위를 한 번씩 지나가요)',
            style: TextStyle(fontSize: 13, color: context.appMuted)),
      ];

  List<Widget> _stopStep() => [
        ..._hint('동작 중에 허브가 정지 버튼 위에서 기다려요. 쉬는 자리는 버튼과 표시창을 '
            '가리지 않는 모서리로 골라 주세요.'),
        _photoPanel(
          label: '정지 버튼과 쉬는 자리를 고르는 사진',
          marks: [
            for (final b in _buttons)
              PanelMark(
                id: b.id,
                kind: b.id == _stopId ? PanelMarkKind.stop : PanelMarkKind.button,
                point: b.point,
                label: b.label,
              ),
            if (_park != null)
              PanelMark(id: 'park', kind: PanelMarkKind.park, point: _park!),
          ],
          onTap: _placingPark
              ? (p) => setState(() {
                    _park = p;
                    _placingPark = false;
                  })
              : null,
        ),
        const SizedBox(height: 12),
        const Text('정지(취소) 버튼',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final b in _buttons)
              ChoiceChip(
                key: Key('wizard-stop-${b.id}'),
                label: Text(b.label),
                selected: _stopId == b.id,
                onSelected: (on) => setState(() { _stopChosen = true; _stopId = on ? b.id : null; }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('정지까지 누를 횟수',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('1번')),
            ButtonSegment(value: 2, label: Text('2번')),
            ButtonSegment(value: 3, label: Text('3번')),
          ],
          selected: {_stopPresses},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _stopPresses = v.first),
        ),
        Text('예: 전자레인지는 1번이면 일시정지, 2번이면 취소인 경우가 많아요.',
            style: TextStyle(fontSize: 13, color: context.appMuted)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('wizard-park'),
          onPressed: () => setState(() => _placingPark = !_placingPark),
          icon: const Icon(Icons.local_parking),
          label: Text(_placingPark
              ? '사진에서 쉬는 자리를 짚어 주세요'
              : (_park == null ? '쉬는 자리 짚기' : '쉬는 자리 다시 짚기')),
        ),
        if (_stopId == null || _park == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '정지 버튼과 쉬는 자리를 둘 다 정해야 동작 중에 정지 버튼 위에서 기다려요. '
              '나중에 정해도 돼요.',
              style: TextStyle(fontSize: 13, color: context.appWarning),
            ),
          ),
      ];

  List<Widget> _passStep() {
    final pass = _pass;
    final mapping = _mapping;
    return [
      ..._hint('허브가 누르지 않고 버튼 위를 한 번씩 지나가요. 버튼 위에 멈추는지 눈으로 확인해 주세요.'),
      Row(
        children: [
          Icon(Icons.check_circle_outline, color: context.appPrimary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${_saved?.name ?? ''} 등록과 버튼 자리를 저장했어요.',
                style: const TextStyle(fontSize: 15)),
          ),
        ],
      ),
      if (mapping != null && mapping.stopParkNotes.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final note in mapping.stopParkNotes)
          Text('· $note', style: TextStyle(fontSize: 14, color: context.appWarning)),
      ],
      const SizedBox(height: 12),
      if (pass == null)
        FilledButton.icon(
          key: const Key('wizard-start-pass'),
          onPressed: _busy ? null : _startPass,
          icon: const Icon(Icons.route),
          label: const Text('확인 주행 시작'),
        )
      else ...[
        if (pass.isMock)
          Text('연습 주행이에요 — 실제로 움직이지 않았어요.',
              key: const Key('wizard-pass-mock'),
              style: TextStyle(fontSize: 15, color: context.appWarning)),
        for (final s in pass.steps)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(_passIcon(s.status), color: _passColor(context, s.status)),
            title: Text(s.label),
            trailing: Text(_passWord(s.status)),
          ),
        if (pass.running) const LinearProgressIndicator(),
        if (!pass.running && (pass.detail ?? '').isNotEmpty)
          Text(pass.detail!, style: TextStyle(fontSize: 14, color: context.appMuted)),
        if (!pass.running)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _startPass,
              child: const Text('다시 지나가 보기'),
            ),
          ),
      ],
      if (pass == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('확인 주행 없이 끝내면, 처음 누를 때 자리가 맞는지 꼭 지켜봐 주세요.',
              style: TextStyle(fontSize: 13, color: context.appMuted)),
        ),
    ];
  }

  static String _passWord(String status) => switch (status) {
        'moving' => '가는 중',
        'reached' => '도착했다고 응답',
        'failed' => '가지 못함',
        'skipped' => '건너뜀',
        _ => '기다리는 중',
      };

  static IconData _passIcon(String status) => switch (status) {
        'moving' => Icons.near_me_outlined,
        'reached' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        'skipped' => Icons.remove_circle_outline,
        _ => Icons.radio_button_unchecked,
      };

  static Color _passColor(BuildContext context, String status) => switch (status) {
        'failed' => context.appDanger,
        'reached' || 'moving' => context.appPrimary,
        _ => context.appMuted,
      };
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '5단계 중 ${step + 1}단계',
        excludeSemantics: true,
        child: Row(
          children: [
            for (var i = 0; i < 5; i++) ...[
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i <= step ? context.appPrimary : context.appBorderSubtle,
                  ),
                ),
              ),
              if (i < 4) const SizedBox(width: 6),
            ],
          ],
        ),
      );
}

/// 사진 위 버튼 자리 → 버튼판 행·열. 세로 간격이 [rowTolerance] 안이면 같은 줄.
({int rows, int cols, List<ApplianceButton> buttons}) gridFromPoints(
  List<(String, String, PhotoPoint)> points, {
  required double rowTolerance,
}) {
  final sorted = [...points]..sort((a, b) => a.$3.y.compareTo(b.$3.y));
  final rows = <List<(String, String, PhotoPoint)>>[];
  for (final p in sorted) {
    if (rows.isNotEmpty) {
      final row = rows.last;
      final meanY =
          row.map((e) => e.$3.y).reduce((a, b) => a + b) / row.length;
      if ((p.$3.y - meanY).abs() <= rowTolerance) {
        row.add(p);
        continue;
      }
    }
    rows.add([p]);
  }
  var cols = 1;
  final buttons = <ApplianceButton>[];
  for (var y = 0; y < rows.length; y++) {
    final row = rows[y]..sort((a, b) => a.$3.x.compareTo(b.$3.x));
    if (row.length > cols) cols = row.length;
    for (var x = 0; x < row.length; x++) {
      buttons.add(ApplianceButton(id: row[x].$1, label: row[x].$2, x: x, y: y));
    }
  }
  return (rows: rows.isEmpty ? 1 : rows.length, cols: cols, buttons: buttons);
}
