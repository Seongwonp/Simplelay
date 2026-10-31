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
import '../widgets/appliance_kind_picker.dart';
import '../widgets/panel_photo_view.dart';
import '../widgets/input_guard.dart';
import '../widgets/appliance_setup_card.dart';
import '../widgets/kit_widgets.dart';
import 'appliance_editor_screen.dart';

/// 가전 추가 6단계:
/// ① 누름 장치 찾기 ② 사진 ③ 누름 장치 칸 맞추기 ④ 버튼 짚고 이름 붙이기 ⑤ 정지 버튼과 기다리는 자리
/// ⑥ 확인 주행. 세트는 버튼 자리를 저장한 뒤에 잇는다 — 중간에 그만둬도 지금 쓰는 가전은 그대로다.
/// 등록된 가전의 자리를 다시 맞출 때는 ①이 없다.
///
/// 누름 장치 범위는 본체에서 받고, 사진 위 네 귀퉁이와 방향을 맞춘다.
///
/// 사진 파일은 전송하지 않는다. 사진 크기와 좌표(px)만 보내고 서버가 mm로 변환한다.
/// 확인 주행은 버튼을 누르지 않으며, 모의 주행은 명시한다.
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
  '누름 장치 찾기',
  '버튼판 사진',
  '누름 장치 칸 맞추기',
  '버튼 고르고 이름 붙이기',
  '정지 버튼과 기다리는 자리',
  '자리 확인',
];

/// 누름 장치 범위 맞추기 안내.
const kAreaHint = '누름 장치가 닿는 칸을 사진 속 장치 자리에 맞춰 주세요';

/// 누름 장치 칸 밖을 짚었을 때 바로 보이는 말(버튼·정지 버튼·기다리는 자리).
const kOutsideAreaMessage = '여기는 누름 장치가 닿지 않아요';

/// 버튼 선택 단계의 정지 버튼 안내.
const kStopTapHint = '정지 버튼도 꼭 찍어 주세요';

/// 본체가 누름 장치 범위를 모를 때.
const kNoWorkspaceMessage = '누름 장치가 닿는 범위를 본체에서 받지 못했어요. 설치하는 분께 범위 설정을 부탁해 주세요.';

/// [corners](볼록 사각형, 어느 방향이든)의 안쪽이나 변 위인가.
bool pointInArea(List<PhotoPoint> corners, PhotoPoint p) {
  if (corners.length != 4) return true;
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    if (c == 0) continue;
    final s = c > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// 정지 버튼이나 기다리는 자리 없이 저장하려 할 때 묻는 창의 본문.
const kNoStopConsequence = '정지 버튼과 기다리는 자리를 둘 다 정하지 않으면, 가전이 도는 중에 멈춰 달라고 해도 '
    '누름 장치가 가전의 정지 버튼을 눌러 드리지 못해요.';

/// 오프라인 저장 실패 안내. 선택 내용은 유지된다.
const kSaveOfflineMessage = '본체와 연결되지 않아 저장하지 못했어요. 와이파이를 확인하고 "저장하고 다음"을 다시 눌러 주세요. 고른 자리는 그대로 있어요.';

/// 본체의 가전 정의가 이 화면을 연 뒤에 바뀌어 저장을 거절했을 때(409). 서버 문장('다른 기기에서')은 다른 기기가
/// 없을 때도 나오고 다음에 할 일을 말하지 않는다.
const kSaveConflictMessage = '본체에 저장된 내용이 그사이 바뀌어 저장하지 않았어요. 닫고 가전 목록을 새로 받은 뒤 다시 맞춰 주세요.';

/// 새 가전을 본체에 올린 뒤 버튼 자리 저장이 안 됐고, 되돌리기(지우기)도 못 했을 때 덧붙이는 말.
const kSaveOrphanNote = '본체에는 이 가전이 버튼 자리 없이 남았을 수 있어요. 다시 저장하거나, 그만두려면 가전 목록에서 지워 주세요.';

/// 현재 구성에서 자리 확인을 지원하지 않을 때의 안내.
const kPassUnavailableMessage = '지금은 자리 확인을 할 수 없어요. 끝내면 이 가전은 "자리 확인 전"으로 남고, 자리 확인을 마칠 때까지 누르지 않아요.';

/// 누름 장치가 없어 자리 확인과 실제 누르기가 모두 불가능할 때의 안내.
const kPassNoPressDeviceMessage = '이 가전에는 아직 누름 장치가 연결되지 않아 자리 확인도, 누르기도 할 수 없어요. '
    '끝낸 뒤 가전 화면에서 세트를 연결해 주세요.';

/// 자리 확인 없이 끝낼 때의 결과.
const kPassSkipNote = '자리 확인 없이 끝내면 이 가전은 "자리 확인 전"으로 남아요. 자리 확인을 마칠 때까지 누르지 않아요.';

class _AddApplianceWizardScreenState
    extends ConsumerState<AddApplianceWizardScreen> {
  // -1은 ① 누름 장치 찾기. 등록된 가전을 다시 맞출 때는 없다.
  late int _step = widget.initial == null ? -1 : 0;

  // ① 누름 장치 세트
  KitStatus? _kit;
  bool _kitLoading = true;
  bool _kitFailed = false;

  /// 다른 가전을 맡은 세트를 이 가전으로 옮겨도 된다고 사람이 확인했나.
  bool _kitReleaseConfirmed = false;

  /// 저장 뒤 세트 연결이 실패했을 때의 이유. 있으면 자리 확인 전에 다시 연결한다.
  String? _bindError;

  // ① 사진
  File? _photo;
  Size? _photoSize;

  /// 이 폰 문서 폴더에 옮겨 둔 사진 경로(찍을 때 옮긴다). 위치를 다시 맞출 때는 등록된 사진에서 시작한다.
  late String? _keptPhoto = widget.initial?.photoPath;
  final _name = TextEditingController(text: '전자레인지');
  final _room = TextEditingController();
  ApplianceCategory _category = ApplianceCategory.microwave;

  // ② 누름 장치 칸 — 사진 위 네 귀퉁이(처음 그린 순서: 왼쪽 위부터 시계 방향)와 장치 방향.
  final List<PhotoPoint> _corners = [];
  MappingFrame? _frame;
  bool _frameLoaded = false;
  AreaOrientation? _orientation;

  /// 사용자가 귀퉁이를 옮겼나. 안 옮겼으면 돌릴 때 칸 비율도 같이 돌려 다시 그린다.
  bool _areaTouched = false;

  /// 사용자가 돌리기·뒤집기를 눌렀나. 처음 연 때와 비교하는 입력([_snapshot])에는 이때만 방향을 넣는다 — 본체 범위를 받아
  /// 기본 방향을 채운 것만으로 '저장하지 않은 내용'이 생기지 않게.
  bool _orientationChanged = false;

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
        _areaTouched = mapping.corners.length == 4;
        // 옛 방식(버튼판 귀퉁이)으로 맞춘 매핑은 방향이 없다 — 본체 범위를 받은 뒤 기본 방향으로 그린다.
        _orientation = mapping.orientation;
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
    if (a == null) unawaited(_loadKit());
  }

  Future<void> _loadKit() async {
    final api = ref.read(rpiApiServiceProvider);
    if (mounted) setState(() => _kitLoading = true);
    KitStatus? kit;
    var failed = api == null;
    if (api != null) {
      try {
        kit = await api.kitStatus();
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _kit = kit;
      _kitFailed = failed;
      _kitLoading = false;
      _error = null;
      // 찾을 때마다 세트가 맡은 가전이 바뀔 수 있다 — 지난 확인을 이어 쓰지 않는다.
      _kitReleaseConfirmed = false;
    });
  }

  Future<void> _releaseKit() async {
    final name = _kit?.boundName;
    if (name == null || !await confirmKitRelease(context, name)) return;
    if (!mounted) return;
    setState(() {
      _kitReleaseConfirmed = true;
      _step = 0;
    });
  }

  /// 버튼 자리를 저장한 뒤 세트를 잇는다. 실패해도 등록·자리는 저장돼 있다 — 이유를 보이고 다시 할 수 있게 둔다.
  Future<void> _bindKit(RpiApiService api) async {
    try {
      await api.bindKit(_id, confirmRelease: _kitReleaseConfirmed);
      if (mounted) setState(() => _bindError = null);
    } on RpiApiException catch (e) {
      if (mounted) setState(() => _bindError = e.statusCode == 0 ? kSaveOfflineMessage : e.message);
    } catch (_) {
      if (mounted) setState(() => _bindError = kSaveOfflineMessage);
    }
  }

  /// 처음 연 때의 입력([_snapshot]). 이와 같으면 닫을 때 묻지 않는다 — 위치를 다시 맞추러 들어와 아무것도
  /// 안 바꿨는데 '저장하지 않은 내용을 잃어요'라고 묻던 것(실화면 10/19).
  late final String _initialSnapshot;

  String _snapshot() => [
        _photo?.path, _name.text, _room.text, _category.value,
        for (final c in _corners) '${c.x},${c.y}',
        for (final b in _buttons) '${b.id}:${b.label}@${b.point.x},${b.point.y}',
        _stopId, _stopPresses, _park == null ? null : '${_park!.x},${_park!.y}',
        _orientationChanged ? '${_orientation?.rotation}/${_orientation?.flipped}' : null,
      ].join('|');

  @override
  void dispose() {
    _poll?.cancel();
    _name.dispose();
    _room.dispose();
    super.dispose();
  }

  // 단계 이동

  bool get _canNext => switch (_step) {
        -1 => !_kitLoading &&
            !_offline &&
            (_kit?.found ?? false) &&
            (_kit?.boundName == null || _kitReleaseConfirmed),
        0 => _photo != null &&
            _photoSize != null &&
            _name.text.trim().isNotEmpty &&
            !_nameTaken &&
            !_offline,
        1 => _corners.length == 4 && _frameReady && _orientation != null,
        2 => _buttons.isNotEmpty,
        3 => !_busy,
        _ => false,
      };

  /// '다음'이 안 눌리는 까닭 한 줄 — [_canNext]와 같은 조건으로만(첫 사용 평가 4차 10/24: 흐린 '다음'에 까닭이 없었다).
  /// 눌리면 null. 저장 중(③)은 단추 글자가 이미 말한다.
  String? get _nextBlockedReason {
    if (_canNext) return null;
    switch (_step) {
      case -1:
        if (_kitLoading) return '누름 장치 세트를 찾는 중이에요';
        if (_kit?.found ?? false) return '세트 연결을 어떻게 할지 골라야 다음으로 갈 수 있어요';
        return '누름 장치 세트를 찾아야 다음으로 갈 수 있어요';
      case 0:
        final noPhoto = _photo == null || _photoSize == null;
        final noName = _name.text.trim().isEmpty;
        if (noPhoto && noName) return '사진과 가전 이름이 있어야 다음으로 갈 수 있어요';
        if (noPhoto) return '가전 사진이 있어야 다음으로 갈 수 있어요';
        if (noName) return '가전 이름을 적어야 다음으로 갈 수 있어요';
        if (_nameTaken) return '같은 이름의 가전이 이미 있어요. 다른 이름을 적어 주세요';
        if (_offline) return '본체와 연결되어야 다음으로 갈 수 있어요';
        return null;
      case 1:
        if (!_frameLoaded) return '누름 장치가 닿는 범위를 본체에서 받는 중이에요';
        return '누름 장치가 닿는 범위를 본체에서 받아야 다음으로 갈 수 있어요';
      case 2:
        return '버튼을 하나 이상 골라야 다음으로 갈 수 있어요';
      default:
        return null;
    }
  }

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

  bool get _frameReady => _frame?.known ?? false;

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
    if (_step == 1) {
      if (!_frameLoaded) {
        unawaited(_loadFrame());
      } else {
        setState(_ensureArea);
      }
    }
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

  /// 범위를 알고 칸이 아직 없으면 사진 가운데에 범위 비율의 칸을 그린다. 방향이 없으면 본체 기본 방향.
  void _ensureArea() {
    final frame = _frame;
    if (frame == null || !frame.known) return;
    _orientation ??= frame.defaultOrientation;
    if (_corners.length != 4 && _photoSize != null) _resetArea();
  }

  /// 칸을 사진 가운데에 다시 그린다 — 장치 X 변이 사진에서 가로면(돌리기 0·180) 가로:세로 = W:H, 세로면 H:W.
  void _resetArea() {
    final size = _photoSize;
    final frame = _frame;
    if (size == null || frame == null || !frame.known) return;
    final xHorizontal = ((_orientation?.rotation ?? 0) ~/ 90).isEven;
    final aspect = xHorizontal ? frame.widthMm! / frame.heightMm! : frame.heightMm! / frame.widthMm!;
    var w = size.width * 0.8;
    var h = w / aspect;
    if (h > size.height * 0.8) {
      h = size.height * 0.8;
      w = h * aspect;
    }
    // 아주 가는 범위(예: 15×115 mm)도 손가락으로 잡을 수 있게 최소 크기를 둔다 — 비율은 처음 그림일 뿐 맞추면 된다.
    w = w.clamp(size.width * 0.25, size.width * 0.8).toDouble();
    h = h.clamp(size.height * 0.25, size.height * 0.8).toDouble();
    final l = (size.width - w) / 2;
    final t = (size.height - h) / 2;
    _corners
      ..clear()
      ..addAll([PhotoPoint(l, t), PhotoPoint(l + w, t), PhotoPoint(l + w, t + h), PhotoPoint(l, t + h)]);
    _areaTouched = false;
  }

  void _rotateArea() => setState(() {
        _orientationChanged = true;
        _orientation = (_orientation ?? const AreaOrientation()).rotated();
        if (!_areaTouched) _resetArea();
      });

  void _flipArea() => setState(() {
        _orientationChanged = true;
        _orientation = (_orientation ?? const AreaOrientation()).mirrored();
      });

  /// 누름 장치 칸 안인가. 밖이면 바로 말하고 false.
  bool _reachable(PhotoPoint p) {
    if (pointInArea(_corners, p)) return true;
    setState(() => _error = kOutsideAreaMessage);
    return false;
  }

  // ① 사진

  Future<void> _takePhoto({bool fromGallery = false}) async {
    final service = ref.read(photoServiceProvider);
    final photo = await service.takePhoto(fromGallery: fromGallery);
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
      _areaTouched = false;
      _buttons.clear();
      _stopId = null;
      _park = null;
    });
  }

  // ② 모서리

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
      _ensureArea();
    });
  }

  // ③ 버튼

  Future<void> _addButton(PhotoPoint p) async {
    if (!_reachable(p)) return;
    if (_error == kOutsideAreaMessage) setState(() => _error = null);
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

  /// ④에서 사진을 짚으면 그 자리를 정지 버튼으로 — ③에서 정지 버튼을 안 찍었어도 여기서 고를 수 있다(실사용 10/26).
  /// 이 단계에서 만든 정지 버튼이 있으면 그 자리만 옮긴다. 다시 맞추기는 이미 있는 버튼 중에서 고른다.
  Future<void> _tapStop(PhotoPoint p) async {
    if (!_reachable(p)) return;
    if (_error == kOutsideAreaMessage) setState(() => _error = null);
    final existing = widget.initial;
    if (existing != null) {
      final free = existing.buttons.where((b) => !_buttons.any((t) => t.id == b.id)).toList();
      if (free.isEmpty) return;
      final chosen = await showDialog<ApplianceButton>(context: context, builder: (dialog) => SimpleDialog(
        title: const Text('이 자리에 있는 정지 버튼을 골라 주세요'),
        children: [for (final b in free)
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog, b), child: Text(b.label)),
        ],
      ));
      if (chosen == null || !mounted) return;
      setState(() {
        _buttons.add(_Tapped(chosen.id, chosen.label, p));
        _stopId = chosen.id;
        _stopChosen = true;
      });
      return;
    }
    setState(() {
      final mine = _buttons.where((b) => b.id == _addedStopId).firstOrNull;
      if (mine != null) _buttons.remove(mine);
      final id = 'B${(_buttonSeq++).toString().padLeft(2, '0')}';
      _buttons.add(_Tapped(id, mine?.label ?? _unique('정지'), p));
      _addedStopId = id;
      _stopId = id;
      _stopChosen = true;
    });
  }

  /// ④에서 사진을 짚어 만든 정지 버튼의 id.
  String? _addedStopId;

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

  // ④ 저장

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
        // mm는 보내지 않는다 — 본체가 아는 누름 장치 범위와 이 방향으로 계산한다.
        orientation: _orientation,
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
      if (widget.initial == null) await _bindKit(api);
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
              orientation: _orientation,
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

  // ⑤ 확인 주행

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
      // 한 번에 하나만 묻는다 — 답(최대 몇 초)을 기다리지 않고 0.8초마다 물으면 요청이 겹쳐, 끝남을 받고 멈춘 뒤 늦게
      // 온 앞 답('하는 중')이 덮어 '끝내기'가 영영 막혔다(검토 10/19). 멈춘 타이머의 답은 받지 않는다.
      var inFlight = false;
      _poll = Timer.periodic(const Duration(milliseconds: 800), (t) async {
        ticks++;
        // 2분이 넘으면 더 기다리지 않는다 -- 상태를 모른다고 말한다.
        if (ticks > 150) {
          t.cancel();
          if (mounted) setState(() => _error = '자리 확인이 어떻게 됐는지 확인하지 못했어요. 본체 화면을 봐 주세요.');
          return;
        }
        if (inFlight) return;
        inFlight = true;
        try {
          final next = await api.verifyPassStatus(_id);
          if (!mounted || !t.isActive || !identical(_poll, t)) return;
          setState(() => _pass = next);
          if (!next.running) t.cancel();
        } catch (_) {
          // 일시적 통신 오류는 다음 주기에 다시 묻는다.
        } finally {
          inFlight = false;
        }
      });
    } on RpiApiException catch (e) {
      // 409: 다른 일을 하는 중(서버 문장 그대로 — 끝난 뒤 다시) 또는 이 구성에서 할 수 없음(쉬운 말과 다음 할 일로).
      final busy = e.message.contains('다른 일') || e.message.contains('진행 중');
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

  // 화면

  @override
  Widget build(BuildContext context) {
    // 연결이 바뀌면 다시 그린다 — 첫 단계의 '다음'과 연결 안내가 [_offline]을 본다.
    ref.watch(rpiConnectionProvider);
    // 끊겨서 세트를 못 찾았으면, 다시 이어진 뒤 사람이 찾기를 또 누르게 하지 않는다.
    ref.listen(rpiConnectionProvider, (previous, next) {
      if (_step == -1 && next == RpiConnectionState.connected && previous != next) unawaited(_loadKit());
    });
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
          Text('${_step + 2}. ${_stepTitles[_step + 1]}',
              key: const Key('wizard-step-title'),
              style: const TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.xs),
          ...switch (_step) {
            -1 => _kitStep(),
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
                            onPressed: _step <= 0 || _busy ? null : _back,
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
              if (_step != 4 && _nextBlockedReason != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: Text(_nextBlockedReason!,
                      key: const Key('wizard-next-why'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
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
    void Function(PanelMark)? onTapMark,
    PanelArea? area,
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
      onTapMark: onTapMark,
      area: area,
      semanticsLabel: label,
    );
  }


  List<Widget> _hint(String text) => [
        Text(text, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        const SizedBox(height: AppSpace.md),
      ];

  List<Widget> _kitStep() => [
        ..._hint('이 가전을 누를 누름 장치 세트를 찾아요. 세트 하나는 가전 하나를 맡아요.'),
        if (_offline)
          Padding(
            key: const Key('wizard-kit-offline'),
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('지금 본체와 연결되지 않아 세트를 찾을 수 없어요.',
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
        KitFindStep(
          kit: _kit,
          loading: _kitLoading,
          failed: _kitFailed,
          releaseConfirmed: _kitReleaseConfirmed,
          onRetry: () => unawaited(_loadKit()),
          onRelease: () => unawaited(_releaseKit()),
        ),
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                key: const Key('wizard-take-photo'),
                onPressed: _takePhoto,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('사진 찍기'),
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton.icon(
                key: const Key('wizard-pick-photo'),
                onPressed: () => _takePhoto(fromGallery: true),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('사진첩에서 고르기'),
              ),
            ]),
          )
        else ...[
          _photoPanel(label: '찍은 버튼판 사진'),
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
            decoration: const InputDecoration(labelText: '방 (안 적어도 돼요, 예: 주방)'),
          ),
          const SizedBox(height: AppSpace.xs),
          ApplianceKindPicker(
            selected: _category,
            onSelected: (c) => setState(() {
              // '기타'는 이름이 아니다 — 비워 두고 적게 한다(실화면 10/19: 이름이 '기타'인 가전이 생겼다).
              if (_name.text.isEmpty || _name.text == _category.label) {
                _name.text = c == ApplianceCategory.other ? '' : c.label;
              }
              _category = c;
            }),
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

  /// 누름 장치 칸(②~④ 사진 위에 늘 겹쳐 그린다). [editable]이면 귀퉁이를 끌 수 있다.
  PanelArea? _area({bool editable = false}) {
    final o = _orientation;
    if (_corners.length != 4 || o == null) return null;
    return PanelArea(
      corners: List.of(_corners),
      orientation: o,
      onCornerMoved: editable
          ? (i, p) => setState(() {
                _corners[i] = p;
                _areaTouched = true;
              })
          : null,
    );
  }

  List<Widget> _cornerStep() {
    final frame = _frame;
    return [
      ..._hint(kAreaHint),
      if (!_frameLoaded)
        const LinearProgressIndicator()
      else if (frame == null || !frame.known) ...[
        Text(kNoWorkspaceMessage,
            key: const Key('wizard-no-workspace'),
            style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(() => _frameLoaded = false);
              unawaited(_loadFrame());
            },
            icon: const Icon(Icons.refresh),
            label: const Text('다시 받기'),
          ),
        ),
      ] else ...[
        _photoPanel(label: '누름 장치 칸을 맞추는 사진', area: _area(editable: true)),
        const SizedBox(height: AppSpace.sm),
        Text('네 귀퉁이 동그라미를 끌어 옮겨요. 장치가 옆으로 놓였으면 "돌리기", 거울처럼 반대면 "뒤집기"로 '
            '원점과 화살표(X, Y · 모터 쪽)를 실제 장치 방향에 맞춰 주세요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        Wrap(
          spacing: AppSpace.sm,
          children: [
            TextButton.icon(
              key: const Key('wizard-area-rotate'),
              onPressed: _rotateArea,
              icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
              label: Text('돌리기 (${_orientation?.rotation ?? 0}°)'),
            ),
            TextButton.icon(
              key: const Key('wizard-area-flip'),
              onPressed: _flipArea,
              icon: const Icon(Icons.flip),
              label: Text((_orientation?.flipped ?? false) ? '뒤집기 (뒤집음)' : '뒤집기'),
            ),
            TextButton.icon(
              key: const Key('wizard-area-reset'),
              onPressed: () => setState(_resetArea),
              icon: const Icon(Icons.crop_free),
              label: const Text('처음 칸으로'),
            ),
          ],
        ),
        Text(
          '누름 장치가 닿는 칸: 가로 ${_mm(frame.widthMm!)}mm, 세로 ${_mm(frame.heightMm!)}mm (본체 설정)',
          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
        ),
      ],
    ];
  }

  static String _mm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  List<Widget> _buttonStep() => [
        ..._hint('누름 장치 칸 안에서 사진 속 버튼을 누르고 이름을 붙여요.'),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Text(kStopTapHint,
              key: const Key('wizard-stop-tap-hint'),
              style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appWarning)),
        ),
        _photoPanel(
          label: '버튼을 고르는 사진, ${_buttons.length}개 골랐어요',
          area: _area(),
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
        // 누름 장치 칸을 그려 둔다 — 그 안쪽만 고를 수 있다.
        ..._hint('가전이 움직이는 동안 누름 장치가 정지 버튼 위에서 기다려요. 정지 버튼은 아래에서 고르거나 사진에서 '
            '바로 눌러 주세요. 기다리는 자리는 누름 장치 칸 안에서 버튼과 표시창을 가리지 않는 곳으로 골라 주세요.'),
        _photoPanel(
          label: '정지 버튼과 기다리는 자리를 고르는 사진',
          area: _area(),
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
              ? (p) {
                  if (!_reachable(p)) return;
                  setState(() {
                    _park = p;
                    _placingPark = false;
                    if (_error == kOutsideAreaMessage) _error = null;
                  });
                }
              : _tapStop,
          // 이미 찍은 버튼을 사진에서 눌러도 정지 버튼으로 고른다.
          onTapMark: _placingPark
              ? null
              : (m) {
                  if (m.kind != PanelMarkKind.button && m.kind != PanelMarkKind.stop) return;
                  setState(() {
                    _stopChosen = true;
                    _stopId = m.id == _stopId ? null : m.id;
                  });
                },
        ),
        const SizedBox(height: AppSpace.md),
        const Text('정지 버튼',
            style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
        if (_buttons.isEmpty || _stopId == null)
          Text('목록에 없으면 사진에서 정지 버튼을 바로 눌러 주세요.',
              key: const Key('wizard-stop-photo-hint'),
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
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
              ? '사진에서 기다리는 자리(대기)를 골라 주세요'
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
      if (_bindError != null) ...[
        const SizedBox(height: AppSpace.sm),
        Text('세트를 연결하지 못했어요. $_bindError',
            key: const Key('wizard-bind-error'),
            style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
        TextButton(
          key: const Key('wizard-bind-retry'),
          onPressed: _busy
              ? null
              : () {
                  final api = ref.read(rpiApiServiceProvider);
                  if (api != null) unawaited(_bindKit(api));
                },
          child: const Text('세트 다시 연결'),
        ),
      ],
      const SizedBox(height: AppSpace.md),
      if (pass == null)
        FilledButton.icon(
          key: const Key('wizard-start-pass'),
          onPressed: _busy || _bindError != null ? null : _startPass,
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
          child: Text(kPassSkipNote,
              key: const Key('wizard-pass-skip-note'),
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
        label: '6개 중 ${step + 2}번째',
        excludeSemantics: true,
        child: Row(
          children: [
            for (var i = 0; i < 6; i++) ...[
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: i <= step + 1 ? context.appPrimary : context.appBorderSubtle,
                  ),
                ),
              ),
              if (i < 5) const SizedBox(width: AppSpace.sm),
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
