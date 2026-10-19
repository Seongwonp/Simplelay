import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/display_status.dart' show applianceNameTaken, nameTakenMessage;
import '../models/hub.dart';
import '../providers/appliance_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
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
  '버튼판 네 귀퉁이 고르기',
  '버튼 고르고 이름 붙이기',
  '정지 버튼과 기다리는 자리',
  '자리 확인',
];

const _cornerNames = ['왼쪽 위', '오른쪽 위', '오른쪽 아래', '왼쪽 아래'];

/// 정지 버튼이나 기다리는 자리 없이 저장하려 할 때 묻는 창의 본문.
const kNoStopConsequence = '정지 버튼과 기다리는 자리를 둘 다 정하지 않으면, 가전이 도는 중에 멈춰 달라고 해도 '
    '누름 장치가 가전의 정지 버튼을 눌러 드리지 못해요.';

/// 본체에 닿지 못해 저장하지 못했을 때 — 무엇을 보고 무엇을 다시 누를지, 고른 것은 남아 있다는 것까지(실화면 10/19).
const kSaveOfflineMessage = '본체와 연결되지 않아 저장하지 못했어요. 와이파이를 확인하고 "저장하고 다음"을 다시 눌러 주세요. 고른 자리는 그대로 있어요.';

/// 본체의 가전 정의가 이 화면을 연 뒤에 바뀌어 저장을 거절했을 때(409). 서버 문장('다른 기기에서')은 다른 기기가
/// 없을 때도 나오고 다음에 할 일을 말하지 않는다.
const kSaveConflictMessage = '본체에 저장된 내용이 그사이 바뀌어 저장하지 않았어요. 닫고 가전 목록을 새로 받은 뒤 다시 맞춰 주세요.';

/// 새 가전을 본체에 올린 뒤 버튼 자리 저장이 안 됐고, 되돌리기(지우기)도 못 했을 때 덧붙이는 말.
const kSaveOrphanNote = '본체에는 이 가전이 버튼 자리 없이 남았을 수 있어요. 다시 저장하거나, 그만두려면 가전 목록에서 지워 주세요.';

/// 본체가 자리 확인을 받지 않을 때(지금 구성에서 할 수 없음). 서버 문장('갠트리' 등)은 처음 쓰는 사람에게 뜻이 없고
/// 다음에 할 일을 말하지 않았다(실화면 10/19).
const kPassUnavailableMessage = '지금은 자리 확인을 할 수 없어요. "자리 확인 없이 끝내기"를 누르고, 처음 누를 때 자리가 맞는지 지켜봐 주세요.';

/// 본체가 이 가전을 누를 장치가 없다고 거절할 때(서버 `VERIFY_NOT_LOCAL_DETAIL` '이 가전 위에는 누름 장치가 없어…', 옛 본체
/// '…갠트리에 연결되지 않았어요'). 자리 확인만이 아니라 누르기도
/// 안 된다 — '처음 누를 때 지켜봐 주세요'라고 하면 누를 수 있는 것처럼 읽혔다(검토 10/19).
const kPassNoPressDeviceMessage = '이 가전에는 아직 누름 장치가 연결되지 않아 자리 확인도, 누르기도 할 수 없어요. '
    '"자리 확인 없이 끝내기"를 누르고, 설치하는 분께 이 가전의 누름 장치 연결을 부탁해 주세요.';

class _AddApplianceWizardScreenState
    extends ConsumerState<AddApplianceWizardScreen> {
  int _step = 0;

  // ① 사진
  File? _photo;
  Size? _photoSize;

  /// 이 폰 문서 폴더에 옮겨 둔 사진 경로(찍을 때 옮긴다). 위치를 다시 맞출 때는 등록된 사진에서 시작한다.
  late String? _keptPhoto = widget.initial?.photoPath;
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
    // 처음 채워 두는 이름이 이미 있는 가전과 겹치면 비워 둔다 — 아무것도 안 했는데 빨간 경고부터 보이지 않게.
    if (a == null && _nameTaken) _name.clear();
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
    _initialSnapshot = _snapshot();
  }

  /// 처음 연 때의 입력([_snapshot]). 이와 같으면 닫을 때 묻지 않는다 — 위치를 다시 맞추러 들어와 아무것도
  /// 안 바꿨는데 '저장하지 않은 내용을 잃어요'라고 묻던 것(실화면 10/19).
  late final String _initialSnapshot;

  String _snapshot() => [
        _photo?.path, _name.text, _room.text, _category.value,
        for (final c in _corners) '${c.x},${c.y}',
        for (final b in _buttons) '${b.id}:${b.label}@${b.point.x},${b.point.y}',
        _stopId, _stopPresses, _park == null ? null : '${_park!.x},${_park!.y}',
        _frameW.text, _frameH.text,
      ].join('|');

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
            _name.text.trim().isNotEmpty &&
            !_nameTaken &&
            !_offline,
        1 => _corners.length == 4 && _frameReady,
        2 => _buttons.isNotEmpty,
        3 => !_busy,
        _ => false,
      };

  /// 본체와 연결되지 않았나. 첫 단계에서 다음으로 가지 않는다 — 안내만 하니 사진·귀퉁이·버튼을 다 고른 뒤 저장에서야
  /// 막혔다(첫 사용 검토 10/19). 연결 화면에 다녀와도 고른 것은 이 화면에 그대로 있다.
  bool get _offline => const {
        RpiConnectionState.unreachable,
        RpiConnectionState.unconfigured,
        RpiConnectionState.keyRequired,
      }.contains(ref.read(rpiConnectionProvider));

  /// 새로 등록하는 이름이 이미 있는가(이름·방이 모두 같은 가전). 위치를 다시 맞출 때는 이름을 바꾸지 않으니 보지 않는다.
  bool get _nameTaken =>
      widget.initial == null &&
      applianceNameTaken(ref.read(installedAppliancesProvider), _name.text, _room.text);

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
      if ((_stopId == null || _park == null) && !await _confirmNoStop()) return;
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

  /// 정지 버튼이나 기다리는 자리 없이 저장하려 할 때 한 번 묻는다. 둘 중 하나라도 없으면 가전이 도는 중에 멈춰 달라고 해도
  /// 가전의 정지 버튼을 누르지 못한다 — '나중에 정해도 돼요'라고 안심시켜 처음 쓰는 사람이 건너뛰었다(첫 사용 검토 10/19).
  /// 막지는 않는다: 켜고 끄는 버튼 하나뿐인 가전은 정지로 고를 버튼이 없고, 그런 버튼을 정지로 고르면 멈출 때 도리어
  /// 다시 켠다.
  Future<bool> _confirmNoStop() async {
    final save = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('정지 버튼 없이 저장할까요?'),
        content: const Text(kNoStopConsequence),
        actions: [
          TextButton(
            key: const Key('wizard-save-without-stop'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('이대로 저장'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('돌아가서 정하기'),
          ),
        ],
      ),
    );
    return save ?? false;
  }

  bool get _dirty => !_transferring && _saved == null && _snapshot() != _initialSnapshot;

  Future<void> _close() async {
    if (_dirty && !await confirmDiscardInput(context)) return;
    if (mounted) Navigator.of(context).pop();
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
    // 찍자마자 문서 폴더로 옮긴다. 저장 단계까지 캐시에 두면 그사이 OS가 캐시를 비워 사진 없이 등록됐다
    // (실화면 10/19: 상세·위치 맞추기에서 사진 자리가 검게 비었다). 같은 등록에서 다시 찍으면 앞서 옮긴 것은 지운다.
    final kept = await service.persist(photo, '${_id}_${DateTime.now().millisecondsSinceEpoch}');
    if (!mounted) return;
    final previous = _keptPhoto;
    if (previous != null && previous != widget.initial?.photoPath) {
      unawaited(File(previous).delete().then((_) {}, onError: (_) {}));
    }
    _keptPhoto = kept;
    setState(() {
      _photo = kept == null ? photo : File(kept);
      _photoSize = size;
      _error = kept == null ? '사진을 이 폰에 남기지 못했어요. 등록은 되지만 나중에 사진이 안 보일 수 있어요.' : null;
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
    // 미리 채운 '버튼 1'은 골라 둔다 — 바로 치면 바뀌게(실화면 10/19: 뒤에 이어 붙었다).
    final controller = TextEditingController(text: initial)
      ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
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
      setState(() => _error = '본체와 연결되면 저장할 수 있어요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // 새 가전을 본체에 올렸는데 버튼 자리 저장이 안 됐으면, 자리 없는 가전이 본체에 남지 않게 되돌린다.
    var registered = false;
    var mappingSaved = false;
    // "내가 본 판" — 다시 맞출 때는 연 가전의 판, 새 가전은 방금 등록이 돌려준 판. 그 사이 다른 곳에서 바꿨으면
    // 본체가 409로 거절한다(검토 10/19: 판을 싣지 않아 충돌 보호를 건너뛰었다). 모르면(0) 밝히지 않는다.
    int? seen = switch (widget.initial?.revision) { final r? when r > 0 => r, _ => null };
    try {
      final draft = await _draftAppliance();
      // 1) 가전과 버튼 이름을 허브에 올린다 -- 매핑은 허브가 아는 버튼에만 붙는다.
      if (widget.initial == null) {
        try {
          final body = await api.registerApplianceStrict(draft);
          registered = true;
          final r = (body['revision'] as num?)?.toInt();
          seen = r != null && r > 0 ? r : null;
        } catch (e) {
          if (!_answerLost(e)) rethrow;
          // 답을 못 받았다 — 본체가 이미 올렸을 수 있다(검토 10/19: 올린 가전을 모른 채 실패로 끝나 본체에만 남았다).
          // 본체 목록에서 이 가전을 찾아 맞춘다. 있으면 이어서 자리를 저장하고, 모르면 되돌리기(지우기)를 해 본다.
          final hub = await _lookupOnHub(api);
          if (hub == null || hub.item != null) registered = true;
          seen = hub?.revision;
          if (hub?.item == null) rethrow;
        }
      }
      // 2) 사진 좌표 → mm. 거절(422)은 서버 문장 그대로.
      MappingSaveResult result;
      ApplianceMap? server;
      final request = MappingRequest(
        photoWidth: size.width.round(),
        photoHeight: size.height.round(),
        corners: _corners,
        buttons: {for (final b in _buttons) b.id: b.point},
        frameWidthMm: (_frame?.known ?? false) ? null : _parsedFrameW,
        frameHeightMm: (_frame?.known ?? false) ? null : _parsedFrameH,
        stopButton: _stopId,
        stopPresses: _stopPresses,
        parkPoint: _park,
        expectedRevision: seen,
      );
      try {
        result = await api.saveMapping(_id, request);
        server = switch (result.appliance) { final json? => ApplianceMap.fromJson(json), _ => null };
      } catch (e) {
        if (!_answerLost(e)) rethrow;
        // 답을 못 받았다 — 본체가 자리를 이미 저장했을 수 있다(검토 10/19). 본체에 저장된 것을 보고 맞춘다. 저장됐으면 그 정의를
        // 이 폰에 받아 끝내고, 아니면 지금 판으로 되돌리기를 한다(그사이 저장돼 판이 올랐으면 본체가 지우기를 거절한다).
        final hub = await _lookupOnHub(api);
        final item = hub?.item;
        if (item == null || !_mappingLanded(item, seen, request)) {
          seen = hub?.revision ?? seen;
          rethrow;
        }
        result = const MappingSaveResult(saved: true);
        server = item;
      }
      mappingSaved = true;
      // 3) 이 폰에 남긴다. 서버가 돌려준 정의(판 번호·사진 매핑)에 이 폰의
      //    사진 경로와 방 이름을 얹는다. 대기열로 다시 올리지 않는다 -- 같은
      //    정의를 또 올리면 방금 계산한 mm 좌표를 덮을 수 있다.
      final local = server == null ? draft : _withLocal(server, draft);
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
      final left = registered && !mappingSaved && !await _undoRegister(api, seen);
      if (mounted) {
        final base = e.statusCode == 0 || e.message.isEmpty
            ? kSaveOfflineMessage
            : e.statusCode == 409
                ? kSaveConflictMessage
                : e.message;
        setState(() => _error = left ? '$base $kSaveOrphanNote' : base);
      }
    } catch (_) {
      final left = registered && !mappingSaved && !await _undoRegister(api, seen);
      if (mounted) setState(() => _error = left ? '$kSaveOfflineMessage $kSaveOrphanNote' : kSaveOfflineMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 본체의 답을 못 받은 실패인가(시간 초과·연결 끊김·본체 오류) — 본체가 이미 저장했을 수 있다. 본체가 이유를 들어
  /// 거절한 것(4xx)은 저장하지 않은 것이다.
  static bool _answerLost(Object e) => e is! RpiApiException || e.statusCode == 0 || e.statusCode >= 500;

  /// 본체 목록에서 이 가전을 찾는다. 목록을 못 받았으면 null(모름), 받았는데 없으면 item이 null.
  Future<({ApplianceMap? item, int? revision})?> _lookupOnHub(RpiApiService api) async {
    final List<ApplianceMap>? list;
    try {
      list = await api.listAppliances();
    } catch (_) {
      return null;
    }
    if (list == null) return null;
    final item = list.where((a) => a.id == _id).firstOrNull;
    return (item: item, revision: item != null && item.revision > 0 ? item.revision : null);
  }

  /// 본체의 [item]에 이번 자리 저장([request])이 들어갔나. 본체의 자리가 보낸 것과 **같아야** 한다 — 판이 오르고 자리가
  /// 있다는 것만 보면 그사이 다른 폰이 저장한 자리를 이 폰의 저장으로 받아 '저장했어요'라고 했다(검토 10/19). 다시 맞추기는
  /// 내가 본 판([seen])보다 판도 올라야 하고, 판을 모르는 다시 맞추기는 가를 수 없어 아니라고 한다(실패로 알린다).
  bool _mappingLanded(ApplianceMap item, int? seen, MappingRequest request) {
    final mapping = item.panelMapping;
    if (mapping == null) return false;
    if (seen != null ? item.revision <= seen : widget.initial != null) return false;
    return mapping.photoWidth.round() == request.photoWidth &&
        mapping.photoHeight.round() == request.photoHeight &&
        listEquals(mapping.corners, request.corners) &&
        request.buttons.entries.every((e) => mapping.buttons[e.key] == e.value) &&
        mapping.parkPoint == request.parkPoint &&
        item.stopButton == request.stopButton;
  }

  /// 방금 올린 새 가전을 본체에서 다시 지운다(버튼 자리 저장이 거절·실패했을 때). 지웠거나 이미 없으면 true.
  Future<bool> _undoRegister(RpiApiService api, int? revision) async {
    try {
      return await api.deleteAppliance(_id, expectedRevision: revision);
    } catch (_) {
      return false;
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
        functions: server.functions,
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

  /// 찍을 때 문서 폴더로 옮긴 경로([_keptPhoto]). 그때 못 옮겼으면 지금 한 번 더 해 본다.
  /// 복사 실패는 등록을 막지 않는다(사진 없이 자리만 남는다).
  Future<String?> _persistPhoto() async {
    final kept = _keptPhoto;
    if (kept != null) return kept;
    final photo = _photo;
    if (photo == null) return null;
    return _keptPhoto = await ref.read(photoServiceProvider).persist(photo, _id);
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
          if (mounted) setState(() => _error = '자리 확인이 어떻게 됐는지 몰라요. 본체 화면을 봐 주세요.');
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
      // 409: 다른 일을 하는 중(서버 문장 그대로 — 끝난 뒤 다시) 또는 이 구성에서 할 수 없음(쉬운 말과 다음 할 일로).
      final busy = e.message.contains('다른');
      final noDevice = e.message.contains('누름 장치가 없어') || e.message.contains('갠트리에 연결되지 않았');
      if (mounted) {
        setState(() => _error = e.statusCode != 409 || busy
            ? e.message
            : noDevice
                ? kPassNoPressDeviceMessage
                : kPassUnavailableMessage);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '자리 확인을 시작하지 못했어요. 연결을 봐 주세요.');
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
    // 연결이 바뀌면 다시 그린다 — 첫 단계의 '다음'과 연결 안내가 [_offline]을 본다.
    ref.watch(rpiConnectionProvider);
    return InputGuard(
      dirty: _dirty,
      // 시스템 뒤로 가기는 한 단계 앞으로(2~4단계). 등록 전체를 닫는 것은 위 X다.
      onBack: _step >= 1 && _step <= 3 ? (_busy ? () {} : _back) : null,
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '닫기',
          icon: const Icon(Icons.close),
          // 뒤로 가기는 한 단계 앞으로 가므로 X는 입력 보호를 직접 묻고 닫는다.
          onPressed: _step == 4 ? _finish : _close,
        ),
        // 등록된 가전의 자리를 다시 맞출 때는 '가전 추가'가 아니다(실화면 10/19: 새로 하나 더 만드는 줄 알았다).
        title: Text(widget.initial == null ? '가전 추가' : '버튼 자리 맞추기'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxl),
        children: [
          _Stepper(step: _step),
          const SizedBox(height: AppSpace.md),
          Text('${_step + 1}. ${_stepTitles[_step]}',
              key: const Key('wizard-step-title'),
              style: const TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.xs),
          ...switch (_step) {
            0 => _photoStep(),
            1 => _cornerStep(),
            2 => _buttonStep(),
            3 => _stopStep(),
            _ => _passStep(),
          },
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 저장 실패는 단추 바로 위에(실화면 10/19: 목록 맨 아래에 붙어 단추 띠에 가려 저장이 안 된 줄 몰랐다).
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(_error!,
                      key: const Key('wizard-error'),
                      style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
                ),
              _step == 4
                  ? FilledButton(
                      key: const Key('wizard-finish'),
                      onPressed: (_pass?.running ?? false) ? null : _finish,
                      child: Text(_pass == null ? '자리 확인 없이 끝내기' : '끝내기'),
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
                        const SizedBox(width: AppSpace.md),
                        Expanded(
                          child: FilledButton(
                            key: const Key('wizard-next'),
                            onPressed: _canNext ? _next : null,
                            // 본체 응답을 기다리는 동안 눌렸는지 알 수 있게(연결이 없으면 수십 초 걸린다, 실화면 10/19).
                            child: Text(_step == 3 ? (_busy ? '저장하는 중…' : '저장하고 다음') : '다음'),
                          ),
                        ),
                      ],
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

  /// 고른 네 귀퉁이 — 버튼·기다리는 자리를 고를 때도 버튼판이 어디까지인지 보이게 그린다.
  List<PanelMark> _cornerMarks() => [
        for (var i = 0; i < _corners.length; i++)
          PanelMark(
            id: 'corner-$i',
            kind: PanelMarkKind.corner,
            point: _corners[i],
            number: i + 1,
          ),
      ];

  List<Widget> _hint(String text) => [
        Text(text, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        const SizedBox(height: AppSpace.md),
      ];

  List<Widget> _photoStep() => [
        ..._hint('버튼판이 다 보이게 찍어 주세요.'),
        // 개인정보 안내는 작은 글씨 한 줄로(2026-10-14 UX).
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: Text('사진은 이 폰에만 남고 본체에는 고른 자리만 보내요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        ),
        // 끝까지 고른 뒤 저장에서야 연결이 없다는 것을 알았다(실화면 10/19) — 시작할 때 말한다.
        if (_offline)
          Padding(
            key: const Key('wizard-offline'),
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('지금 본체와 연결되지 않아 다음으로 갈 수 없어요. 연결하고 돌아오면 찍은 사진과 적은 이름은 그대로 있어요.',
                    style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
                OutlinedButton.icon(
                  key: const Key('wizard-connect'),
                  onPressed: () => context.push('/settings/hub'),
                  icon: const Icon(Icons.wifi_rounded),
                  label: const Text('본체 연결하기'),
                ),
              ],
            ),
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
        const SizedBox(height: AppSpace.md),
        // 등록된 가전의 자리를 다시 맞출 때는 이름·방·종류를 여기서 바꾸지 않는다 — 칸만 열려 있고 저장되지 않았다(실화면 10/19).
        if (widget.initial case final a?)
          Text('가전: ${a.name}', key: const Key('wizard-fixed-name'),
              style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w600))
        else ...[
          TextField(
            key: const Key('wizard-name'),
            controller: _name,
            maxLength: 40,
            decoration: InputDecoration(
              labelText: '가전 이름 (예: 전자레인지)',
              errorText: _nameTaken ? nameTakenMessage(_name.text) : null,
              errorMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _room,
            onChanged: (_) => setState(() {}),
            maxLength: 20,
            decoration: const InputDecoration(labelText: '방 (선택, 예: 주방)'),
          ),
          const SizedBox(height: AppSpace.xs),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final c in ApplianceCategory.values)
                ChoiceChip(
                  avatar: Icon(c.icon, size: 18),
                  label: Text(c.label),
                  selected: _category == c,
                  onSelected: (_) => setState(() {
                    // '기타'는 이름이 아니다 — 비워 두고 적게 한다(실화면 10/19: 이름이 '기타'인 가전이 생겼다).
                    if (_name.text.isEmpty || _name.text == _category.label) {
                      _name.text = c == ApplianceCategory.other ? '' : c.label;
                    }
                    _category = c;
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
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
        ],
      ];

  List<Widget> _cornerStep() {
    final nextCorner = _corners.length < 4 ? _cornerNames[_corners.length] : null;
    return [
      ..._hint(nextCorner == null
          // 크기 칸이 사진 아래라 화면 밖이다 — '다음'이 왜 안 눌리는지 위에서 말한다(실화면 10/19).
          ? (_frameLoaded && !_frameReady
              ? '네 귀퉁이를 모두 골랐어요. 아래에 버튼판 가로·세로 크기(mm)를 적으면 다음으로 갈 수 있어요.'
              : '네 귀퉁이를 모두 골랐어요. 틀렸으면 "다시 고르기"를 눌러 주세요.')
          : '사진에서 버튼판 귀퉁이를 왼쪽 위부터 차례로 눌러 주세요. 지금: $nextCorner'),
      _photoPanel(
        label: '버튼판 귀퉁이를 고르는 사진',
        marks: _cornerMarks(),
        onTap: _corners.length >= 4
            ? null
            : (p) => setState(() => _corners.add(p)),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _corners.isEmpty ? null : () => setState(_corners.clear),
          icon: const Icon(Icons.undo),
          label: const Text('다시 고르기'),
        ),
      ),
      if (!_frameLoaded)
        const LinearProgressIndicator()
      else if (_frame?.known ?? false)
        Text(
          '버튼판 크기: 가로 ${_frame!.widthMm!.toStringAsFixed(0)}mm, 세로 ${_frame!.heightMm!.toStringAsFixed(0)}mm',
          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
        )
      else ...[
        Text('버튼판 크기를 아직 몰라요. 자로 잰 안쪽 크기를 적어 주세요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
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
            const SizedBox(width: AppSpace.md),
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
          label: '버튼을 고르는 사진, ${_buttons.length}개 골랐어요',
          marks: [
            ..._cornerMarks(),
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
        const SizedBox(height: AppSpace.md),
        if (_buttons.isEmpty)
          Text('아직 고른 버튼이 없어요',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
        else
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
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
        const SizedBox(height: AppSpace.sm),
        Text('다음은 정지 버튼과 기다리는 자리, 그다음은 자리 확인이에요. 누름 장치가 버튼 위를 한 번씩 지나가요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
      ];

  List<Widget> _stopStep() => [
        // '모서리'라고만 하니 사진 모서리(버튼판 밖)를 골라 거절됐다(실화면 10/19) — 네 귀퉁이 안쪽이라고 말하고 귀퉁이를 그려 둔다.
        ..._hint('가전이 움직이는 동안 누름 장치가 정지 버튼 위에서 기다려요. 기다리는 자리는 번호 붙은 네 귀퉁이 안쪽에서 '
            '버튼과 표시창을 가리지 않는 곳으로 골라 주세요.'),
        _photoPanel(
          label: '정지 버튼과 기다리는 자리를 고르는 사진',
          marks: [
            ..._cornerMarks(),
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
        const SizedBox(height: AppSpace.md),
        const Text('정지 버튼',
            style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
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
        const SizedBox(height: AppSpace.md),
        const Text('정지까지 누를 횟수',
            style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.sm),
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
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        const SizedBox(height: AppSpace.md),
        OutlinedButton.icon(
          key: const Key('wizard-park'),
          onPressed: () => setState(() => _placingPark = !_placingPark),
          icon: const Icon(Icons.local_parking),
          label: Text(_placingPark
              ? '사진에서 기다리는 자리를 골라 주세요'
              : (_park == null ? '기다리는 자리 고르기' : '기다리는 자리 다시 고르기')),
        ),
        if (_stopId == null || _park == null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              '중간에 안전하게 멈추려면 정지 버튼과 기다리는 자리를 모두 정해 주세요. '
              '정하지 않으면 가전이 도는 중에 멈춰 달라고 해도 누름 장치가 가전의 정지 버튼을 눌러 드리지 못해요.',
              key: const Key('wizard-stop-missing'),
              style: TextStyle(fontSize: AppFont.caption, color: context.appWarning),
            ),
          ),
      ];

  List<Widget> _passStep() {
    final pass = _pass;
    final mapping = _mapping;
    return [
      ..._hint('누름 장치가 누르지 않고 버튼 위를 한 번씩 지나가요. 버튼 위에 멈추는지 눈으로 봐 주세요.'),
      Row(
        children: [
          Icon(Icons.check_circle_outline, color: context.appPrimary),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text('${_saved?.name ?? ''} 등록과 버튼 자리를 저장했어요.',
                style: const TextStyle(fontSize: AppFont.caption)),
          ),
        ],
      ),
      if (mapping != null && mapping.stopParkNotes.isNotEmpty) ...[
        const SizedBox(height: AppSpace.sm),
        for (final note in mapping.stopParkNotes)
          Text('· $note', style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
      ],
      const SizedBox(height: AppSpace.md),
      if (pass == null)
        FilledButton.icon(
          key: const Key('wizard-start-pass'),
          onPressed: _busy ? null : _startPass,
          icon: const Icon(Icons.route),
          label: const Text('자리 확인 시작'),
        )
      else ...[
        if (pass.isMock)
          Text('연습이라 누름 장치는 실제로 움직이지 않았어요.',
              key: const Key('wizard-pass-mock'),
              style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
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
          Text(pass.detail!, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
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
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text('자리 확인 없이 끝내면 처음 누를 때 자리가 맞는지 꼭 지켜봐 주세요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        ),
    ];
  }

  static String _passWord(String status) => switch (status) {
        'moving' => '가는 중',
        'reached' => '도착했다고 알려 왔어요',
        'failed' => '가지 못했어요',
        'skipped' => '건너뛰었어요',
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
        label: '5개 중 ${step + 1}번째',
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
              if (i < 4) const SizedBox(width: AppSpace.sm),
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
