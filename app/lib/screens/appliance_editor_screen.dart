import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../models/appliance.dart';
import '../models/display_status.dart' show applianceNameTaken, kNameTakenMessage;
import '../providers/appliance_provider.dart';
import '../providers/appliance_sync_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/panel_scan_fill.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/app_text.dart';
import '../widgets/input_guard.dart';

const _minGridSize = 1;
const _maxGridSize = 6;

class ApplianceDraft {
  const ApplianceDraft({required this.name, required this.room, required this.category});
  final String name;
  final String room;
  final ApplianceCategory category;
}

class ApplianceEditorScreen extends ConsumerStatefulWidget {
  const ApplianceEditorScreen({super.key, this.draft});
  final ApplianceDraft? draft;

  @override
  ConsumerState<ApplianceEditorScreen> createState() =>
      _ApplianceEditorScreenState();
}

class _ApplianceEditorScreenState extends ConsumerState<ApplianceEditorScreen> {
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();

  /// 어떤 종류의 가전인가. 이름으로 추측하지 않고 사용자가 고른다 --
  /// "에어컨 옆 선풍기" 같은 이름을 잘못 읽으면 고칠 방법이 없다.
  ApplianceCategory _category = ApplianceCategory.other;
  int _rows = 3;
  int _cols = 3;
  late List<List<String?>> _grid = _emptyGrid(_rows, _cols);
  File? _photo;

  /// 사진 인식 요청 중. 끝날 때까지 다시 찍기·제거·재요청을 막는다 --
  /// 중간에 사진이 바뀌면 다른 사진의 결과가 격자에 들어간다.
  bool _scanning = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    if (draft != null) {
      _nameController.text = draft.name;
      _locationController.text = draft.room;
      _category = draft.category;
    }
    // 아래 고정 줄이 지금까지 적은 것을 되풀이한다 -- 입력을 따라가야 한다.
    _nameController.addListener(_refresh);
    _locationController.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  /// 이름과 방이 모두 같은 가전이 이미 있는가 — 있으면 저장하지 않는다(실화면 10/19).
  /// 저장한 뒤에는 방금 등록한 그 가전과 겹치므로 보지 않는다.
  bool get _nameTaken => !_saved && applianceNameTaken(
      ref.read(installedAppliancesProvider), _nameController.text, _locationController.text);

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  List<List<String?>> _emptyGrid(int rows, int cols) =>
      List.generate(rows, (_) => List<String?>.filled(cols, null));

  void _resize({int? rows, int? cols}) {
    final nextRows = (rows ?? _rows).clamp(_minGridSize, _maxGridSize);
    final nextCols = (cols ?? _cols).clamp(_minGridSize, _maxGridSize);
    final next = _emptyGrid(nextRows, nextCols);
    for (var y = 0; y < _rows && y < nextRows; y++) {
      for (var x = 0; x < _cols && x < nextCols; x++) {
        next[y][x] = _grid[y][x];
      }
    }
    setState(() {
      _rows = nextRows;
      _cols = nextCols;
      _grid = next;
    });
  }

  Future<void> _takePhoto() async {
    final photo = await ref.read(photoServiceProvider).takePhoto();
    if (photo == null || !mounted) return;
    setState(() => _photo = photo);
  }

  void _removePhoto() => setState(() => _photo = null);

  /// 찍은 사진을 서버에 보내 버튼 배치 **초안**을 받아 격자를 채운다.
  ///
  /// 초안은 저장하지 않는다 -- 격자에 채울 뿐이고, 사람이 이름과 위치를
  /// 확인한 뒤 평소처럼 저장한다.
  Future<void> _fillFromPhoto() async {
    final photo = _photo;
    if (photo == null || _scanning) return;
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      await _showScanProblem('본체와 아직 연결되지 않았어요. 설정에서 본체를 먼저 연결해 주세요.');
      return;
    }
    // 사진은 기기 밖으로, 그것도 인터넷 너머로 나간다. 버튼을 하나도 적지
    // 않은 새 가전에서도 한 번은 묻는다 -- 탭 한 번에 사진이 전송되면
    // 사용자가 전송 사실을 모른 채 지나갈 수 있다.
    final send = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('사진을 외부 인식 서비스로 보낼까요?'),
        content: Text(
          _buttonCount > 0
              ? '사진이 본체를 거쳐 인터넷의 외부 인식 서비스로 가요.\n'
                  '적어 둔 버튼 $_buttonCount개가 읽은 결과로 바뀌어요.'
              : '사진이 본체를 거쳐 인터넷의 외부 인식 서비스로 가요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('보내기'),
          ),
        ],
      ),
    );
    if (send != true || !mounted) return;

    setState(() => _scanning = true);
    String? problem;
    var details = const <String>[];
    PanelScanFill? fill;
    var dropped = const <String>[];
    try {
      final bytes = await ref.read(photoServiceProvider).readBytes(photo);
      final draft = await api.scanPanel(bytes);
      dropped = draft.dropped;
      final result = fillFromPanelScan(draft, maxGrid: _maxGridSize);
      if (result.filled == 0) {
        problem = '사진에서 앱에 넣을 수 있는 버튼을 찾지 못했어요.';
        details = [...result.skipped, ...draft.dropped];
      } else {
        fill = result;
      }
    } on PanelScanFillException catch (e) {
      problem = e.message;
    } on RpiApiException catch (e) {
      problem = e.message;
    } on FileSystemException {
      problem = '사진 파일을 읽지 못했어요. 다시 찍어 주세요.';
    } on Exception {
      problem = '사진으로 채우지 못했어요. 잠시 뒤 다시 해 주세요.';
    }
    if (!mounted) return;

    final applied = fill;
    setState(() {
      _scanning = false;
      if (applied != null) {
        _rows = applied.rows;
        _cols = applied.cols;
        _grid = applied.grid;
      }
    });
    if (applied == null) {
      await _showScanProblem(problem ?? '사진으로 채우지 못했어요.', details: details);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _ScanResultDialog(fill: applied, dropped: dropped),
    );
  }

  Future<void> _showScanProblem(
    String message, {
    List<String> details = const [],
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('사진으로 채우지 못했어요'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              for (final d in details.take(6)) ...[
                const SizedBox(height: AppSpace.sm),
                Text('· $d', style: dialogContext.appCaption),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _editCell(int x, int y) async {
    final existing = _grid[y][x];
    final controller = TextEditingController(text: existing ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? '버튼 추가' : '버튼 수정'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '버튼 이름 (예: 시작)'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, ''),
              child: Text('삭제', style: TextStyle(color: context.appDanger)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _grid[y][x] = result.isEmpty ? null : result);
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('가전 이름을 적어 주세요.')));
      return;
    }
    if (_nameTaken) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(kNameTakenMessage)));
      return;
    }

    final buttons = <ApplianceButton>[];
    var counter = 1;
    for (var y = 0; y < _rows; y++) {
      for (var x = 0; x < _cols; x++) {
        final label = _grid[y][x];
        if (label != null) {
          buttons.add(
            ApplianceButton(
                id: 'custom_btn_${counter++}', label: label, x: x, y: y),
          );
        }
      }
    }
    if (buttons.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('버튼을 하나 이상 넣어 주세요.')));
      return;
    }

    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';

    // 사진은 image_picker의 임시 캐시에 있어서 OS가 언제든 지울 수 있다 —
    // 문서 폴더로 복사한 영구 경로를 저장한다. 복사 실패는 등록을 막지 않는다.
    String? photoPath;
    final photo = _photo;
    if (photo != null) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/appliance_photos');
        await dir.create(recursive: true);
        final saved = await photo.copy('${dir.path}/$id.jpg');
        photoPath = saved.path;
      } catch (_) {
        photoPath = null;
      }
    }

    // 빈 칸은 빈 문자열이 아니라 '없음'이다 -- 빈 문자열을 들고 다니면
    // 화면마다 isEmpty 검사를 다시 해야 한다.
    final location = _locationController.text.trim();

    final appliance = ApplianceMap(
      id: id,
      name: name,
      location: location.isEmpty ? null : location,
      category: _category,
      rows: _rows,
      cols: _cols,
      buttons: buttons,
      isCustom: true,
      photoPath: photoPath,
    );

    // 로컬 저장 + 서버 전달을 **대기열을 통해** 한다. 예전에는 여기서
    // 바로 registerAppliance를 부르고 실패하면 스낵바로 끝냈다 — 서버가
    // 꺼져 있을 때 등록한 가전은 사용자가 '다시 동기화'를 기억해서 눌러
    // 줘야만 올라갔고, 기억 못 하면 키오스크가 영영 몰랐다.
    final result =
        await ref.read(applianceSyncProvider.notifier).saveAppliance(appliance);
    await ref.read(selectedApplianceProvider.notifier).select(appliance);

    if (!mounted) return;
    setState(() => _saved = true);
    // 등록됐다는 것과 조작할 수 있다는 것은 다르다. 여기서 바로 사라지면,
    // 사용자는 다 끝난 줄 알고 홈으로 가서 '아직 연결되지 않았어요'를
    // 만나고, 자기가 뭘 잘못했는지 되짚게 된다. 남은 일을 지금 말한다.
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _SavedNextStepsDialog(
        name: name,
        syncPending: result.failed > 0,
        onGoToSettings: () {
          Navigator.of(dialogContext).pop();
          context.pop();
          context.push('/appliance/setup', extra: appliance);
        },
        onLater: () {
          Navigator.of(dialogContext).pop();
          context.pop();
        },
      ),
    );
  }

  int get _buttonCount =>
      _grid.expand((row) => row).where((cell) => cell != null).length;

  @override
  Widget build(BuildContext context) {
    // 등록은 진짜 순서다: 종류를 골라야 그림이 정해지고, 사진을 찍어야
    // 격자를 그 위에 겹칠 수 있다. 그래서 번호를 붙인다 -- 장식이 아니다.
    // 카드로 나누지 않는다. 제목·여백·구분선으로 단계를 만든다.
    final divider = Divider(height: 40, color: context.appBorderFaint);
    final name = _nameController.text.trim();
    final location = _locationController.text.trim();

    return InputGuard(
      dirty: !_saved && (name.isNotEmpty || location.isNotEmpty || _buttonCount > 0 || _photo != null),
      child: Scaffold(
      appBar: AppBar(title: const Text('새 가전 추가')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxl),
        children: [
          Text(
            '가전의 버튼 자리를 그대로 등록하면 누름 장치가 그 버튼을 대신 눌러요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.xxl),

          // ── 1. 종류 ─────────────────────────────────────────────────────
          const _StepTitle(number: 1, title: '어떤 가전인가요?'),
          const SizedBox(height: AppSpace.xs),
          Text(
            '고른 종류에 맞는 그림으로 보여드려요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final c in ApplianceCategory.values)
                Semantics(
                  button: true,
                  selected: c == _category,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _category = c),
                    child: Container(
                      // 고령 사용자 기준 최소 터치 대상.
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.lg, vertical: AppSpace.md),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: c == _category
                              ? context.appPrimary
                              : context.appBorderSubtle,
                          width: c == _category ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(c.icon,
                              size: 18,
                              color: c == _category
                                  ? context.appPrimary
                                  : context.appMuted),
                          const SizedBox(width: AppSpace.sm),
                          Text(
                            c.label,
                            style: TextStyle(
                              fontSize: AppFont.caption,
                              fontWeight: c == _category
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: c == _category
                                  ? context.appPrimary
                                  : context.appOnSurfaceSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          divider,

          // ── 2. 이름과 위치 ─────────────────────────────────────────────
          const _StepTitle(number: 2, title: '이름과 위치'),
          const SizedBox(height: AppSpace.md),
          Text('가전 이름',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: '예: 식기세척기',
              errorText: _nameTaken ? kNameTakenMessage : null,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          Text('어디에 있나요?',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          const SizedBox(height: AppSpace.xs),
          Text(
            '같은 종류를 여러 대 등록할 수 있어요. 위치를 적어두면 목록에서 헷갈리지 않아요. 비워 둬도 돼요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _locationController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '예: 거실',
            ),
          ),
          divider,

          // ── 3. 사진 (선택) ─────────────────────────────────────────────
          // 사진은 필수가 아니다. 없어도 등록과 조작이 그대로 된다 -- 있으면
          // 홈의 그림이 되고, 아래 격자를 그 위에 겹쳐 실제 위치를 보며
          // 배치할 수 있다.
          if (widget.draft == null) ...[
          const _StepTitle(number: 3, title: '사진', optional: true),
          const SizedBox(height: AppSpace.xs),
          Text(
            '버튼판이 화면에 꽉 차게 찍어 주세요. 사진 없이도 넘어갈 수 있어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.md),
          _photo == null
              ? OutlinedButton.icon(
                  onPressed: _takePhoto,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('버튼판 사진 찍기'),
                )
              : Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _scanning ? null : _takePhoto,
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('다시 찍기'),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    IconButton(
                      onPressed: _scanning ? null : _removePhoto,
                      icon: const Icon(Icons.close),
                      tooltip: '사진 제거',
                    ),
                  ],
                ),
          if (_photo != null) ...[
            const SizedBox(height: AppSpace.md),
            // 사진 인식은 선택이다. 버튼판을 직접 적는 경로는 그대로 남는다.
            FilledButton.tonalIcon(
              key: const ValueKey('panel_scan_button'),
              onPressed: _scanning ? null : _fillFromPhoto,
              icon: _scanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(_scanning ? '사진을 읽는 중… 최대 1분' : '사진으로 버튼 채우기'),
            ),
            const SizedBox(height: AppSpace.sm),
            // 사진이 기기 밖으로 나가는 유일한 경로라, 누르기 전에 말한다.
            Text(
              '누르면 사진이 본체를 거쳐 인터넷의 외부 인식 서비스로 보내져요. 결과를 보고 고친 뒤 저장해요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
          divider,

          ],
          // ── 4. 버튼 배치 ───────────────────────────────────────────────
          const _StepTitle(number: 4, title: '버튼 배치'),
          const SizedBox(height: AppSpace.xs),
          Text(
            '실제 버튼이 있는 자리를 눌러 이름을 적어요. 줄과 칸 수는 가전 버튼판에 맞춰요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: _StepperField(
                  label: '줄',
                  value: _rows,
                  min: _minGridSize,
                  max: _maxGridSize,
                  onChanged: (v) => _resize(rows: v),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _StepperField(
                  label: '칸',
                  value: _cols,
                  min: _minGridSize,
                  max: _maxGridSize,
                  onChanged: (v) => _resize(cols: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          AspectRatio(
            aspectRatio: _cols / _rows,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_photo != null) Image.file(_photo!, fit: BoxFit.cover),
                  _EditableGrid(
                    grid: _grid,
                    onTapCell: _editCell,
                    translucent: _photo != null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            '말로 시키기는 아직 안 돼요. 저장하면 화면에서 버튼을 직접 누를 수 있어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
        ],
      ),
      // 저장은 스크롤과 무관하게 손 닿는 자리에. 무엇을 저장하는지와 그다음에
      // 무엇이 남는지를 같이 말한다 -- 저장이 끝이라고 믿게 두지 않는다.
      bottomNavigationBar: Material(
        color: context.appBackground,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.md),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.appBorderFaint)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  [
                    _category.label,
                    if (location.isNotEmpty || name.isNotEmpty)
                      [location, name].where((t) => t.isNotEmpty).join(' '),
                    '버튼 $_buttonCount개',
                  ].join(' · '),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  '저장한 뒤에 위치 맞추기와 자리 확인을 이어 해요.',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
                const SizedBox(height: AppSpace.md),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: const Text('저장'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// 사진 인식으로 격자를 채운 뒤 **확인할 것**을 말한다.
///
/// 인식은 틀릴 수 있다. '채웠어요'만 말하고 닫으면 사용자는 결과를 믿고
/// 그대로 저장한다 -- 이름을 못 읽은 버튼과 넣지 않은 조작을 여기서 짚는다.
class _ScanResultDialog extends StatelessWidget {
  const _ScanResultDialog({required this.fill, required this.dropped});

  final PanelScanFill fill;

  /// 서버가 인식 결과에서 뺀 항목.
  final List<String> dropped;

  @override
  Widget build(BuildContext context) {
    final left = [...fill.skipped, ...dropped];
    return AlertDialog(
      title: Text('버튼 ${fill.filled}개를 채웠어요'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '읽은 결과는 틀릴 수 있어요. 이름과 자리가 실제 버튼판과 같은지 보고 저장해 주세요.',
              style: TextStyle(color: context.appMuted),
            ),
            if (fill.unnamed.isNotEmpty) ...[
              const SizedBox(height: AppSpace.lg),
              const Text('이름을 읽지 못한 버튼',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpace.xs),
              Text(
                '${fill.unnamed.join(', ')}. 칸을 눌러 이름을 고쳐 주세요.',
                style: context.appCaption,
              ),
            ],
            if (left.isNotEmpty) ...[
              const SizedBox(height: AppSpace.lg),
              const Text('넣지 않은 것',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              for (final item in left.take(6)) ...[
                const SizedBox(height: AppSpace.xs),
                Text('· $item', style: context.appCaption),
              ],
              if (left.length > 6) ...[
                const SizedBox(height: AppSpace.xs),
                Text('외 ${left.length - 6}개', style: context.appCaption),
              ],
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          // 알려 주기만 하는 창은 '닫기'(평가 17차 10/18: 폰 안 닫는 단추 말 통일).
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

/// 등록 단계의 제목. 번호는 장식이 아니라 실제 순서다.
class _StepTitle extends StatelessWidget {
  const _StepTitle({
    required this.number,
    required this.title,
    this.optional = false,
  });

  final int number;
  final String title;
  final bool optional;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: context.appInk,
            child: Text(
              '$number',
              style: TextStyle(
                color: context.appOnAccent,
                fontWeight: FontWeight.w700,
                fontSize: AppFont.caption,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Flexible(child: Text(title, style: AppText.title)),
          if (optional) ...[
            const SizedBox(width: AppSpace.sm),
            Text('선택', style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ],
        ],
      );
}

/// 저장 직후 **남은 일**을 말한다.
///
/// "저장했어요"만 하고 닫으면, 사용자는 다 끝난 줄 알고 홈에서 조작을
/// 시도하다가 '아직 연결되지 않았어요'를 만난다. 그때는 원인을 자기
/// 가전에서 찾게 된다 -- 실제로는 아직 아무것도 잘못되지 않았는데도.
class _SavedNextStepsDialog extends StatelessWidget {
  const _SavedNextStepsDialog({
    required this.name,
    required this.syncPending,
    required this.onGoToSettings,
    required this.onLater,
  });

  final String name;

  /// 키오스크/서버 반영이 아직 안 됐는가. 대기열이 알아서 다시 시도한다.
  final bool syncPending;

  final VoidCallback onGoToSettings;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text("'$name'을 등록했어요"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('아직 쓸 수는 없어요. 두 가지가 남았어요.',
                style: TextStyle(color: context.appMuted)),
            const SizedBox(height: AppSpace.lg),
            const _NextStep(
              icon: Icons.link,
              title: '위치 맞추기',
              body: '조작부 사진에서 버튼 위치를 맞춰 주세요.',
            ),
            const SizedBox(height: AppSpace.md),
            const _NextStep(
              icon: Icons.center_focus_strong_outlined,
              title: '자리 확인',
              body: '누름 장치가 버튼 위를 지나가는지 눈으로 봐 주세요.',
            ),
            if (syncPending) ...[
              const SizedBox(height: AppSpace.lg),
              Text(
                '지금은 본체와 연결이 끊겨 있어요. 연결되면 다시 보낼게요.',
                style: context.appCaption,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: onLater, child: const Text('다음에')),
          FilledButton(onPressed: onGoToSettings, child: const Text('위치 맞추기')),
        ],
      );
}

class _NextStep extends StatelessWidget {
  const _NextStep(
      {required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.appMuted),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpace.xs),
                Text(body, style: context.appCaption),
              ],
            ),
          ),
        ],
      );
}

class _StepperField extends StatelessWidget {
  const _StepperField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppText.body),
          Row(
            children: [
              IconButton(
                onPressed: value > min ? () => onChanged(value - 1) : null,
                icon: const Icon(Icons.remove_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
              Text('$value', style: AppText.title),
              IconButton(
                onPressed: value < max ? () => onChanged(value + 1) : null,
                icon: const Icon(Icons.add_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditableGrid extends StatelessWidget {
  const _EditableGrid({
    required this.grid,
    required this.onTapCell,
    this.translucent = false,
  });

  final List<List<String?>> grid;
  final void Function(int x, int y) onTapCell;
  // 뒤에 사진이 깔려 있을 때 — 빈 칸은 사진이 그대로 비치게, 채워진 칸은
  // 라벨이 사진 위에서도 읽히게 배경을 좀 더 진하게 준다.
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    final rows = grid.length;
    final cols = rows == 0 ? 0 : grid[0].length;
    return Column(
      children: List.generate(rows, (y) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: y < rows - 1 ? AppSpace.sm : 0),
            child: Row(
              children: List.generate(cols, (x) {
                final label = grid[y][x];
                final filled = label != null;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: x < cols - 1 ? AppSpace.sm : 0),
                    child: GestureDetector(
                      key: ValueKey('grid_cell_${x}_$y'),
                      onTap: () => onTapCell(x, y),
                      child: Container(
                        decoration: BoxDecoration(
                          color: filled
                              ? context.appPrimary
                                  .withValues(alpha: translucent ? 0.28 : 0.14)
                              // translucent(사진 위 오버레이)는 사진 대비를 위해
                              // 흰색 유지가 의도 — 일반 모드만 테마 토큰 사용
                              : (translucent
                                  ? Colors.transparent
                                  : context.appOverlayFaint),
                          border: Border.all(
                            color: filled
                                ? context.appPrimary
                                : (translucent
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : context.appBorderSubtle),
                            width: filled ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        alignment: Alignment.center,
                        child: filled
                            ? Text(
                                label,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppFont.caption,
                                  fontWeight: FontWeight.w600,
                                  color: translucent
                                      ? Colors.white
                                      : context.appPrimary,
                                  shadows: translucent
                                      ? const [
                                          Shadow(
                                              blurRadius: 4,
                                              color: Colors.black)
                                        ]
                                      : null,
                                ),
                              )
                            : (translucent
                                ? null
                                : Icon(Icons.add,
                                    size: 16, color: context.appOutline)),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        );
      }),
    );
  }
}
