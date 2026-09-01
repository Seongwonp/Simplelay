import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../models/appliance.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/appliance_provider.dart';
import '../providers/photo_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

const _minGridSize = 1;
const _maxGridSize = 6;

class ApplianceEditorScreen extends ConsumerStatefulWidget {
  const ApplianceEditorScreen({super.key});

  @override
  ConsumerState<ApplianceEditorScreen> createState() =>
      _ApplianceEditorScreenState();
}

class _ApplianceEditorScreenState extends ConsumerState<ApplianceEditorScreen> {
  final _nameController = TextEditingController();
  int _rows = 3;
  int _cols = 3;
  late List<List<String?>> _grid = _emptyGrid(_rows, _cols);
  File? _photo;

  @override
  void dispose() {
    _nameController.dispose();
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
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
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
          .showSnackBar(const SnackBar(content: Text('가전 이름을 입력하세요.')));
      return;
    }

    final buttons = <ApplianceButton>[];
    var counter = 1;
    for (var y = 0; y < _rows; y++) {
      for (var x = 0; x < _cols; x++) {
        final label = _grid[y][x];
        if (label != null) {
          buttons.add(
            ApplianceButton(id: 'custom_btn_${counter++}', label: label, x: x, y: y),
          );
        }
      }
    }
    if (buttons.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('버튼을 하나 이상 추가하세요.')));
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

    final appliance = ApplianceMap(
      id: id,
      name: name,
      icon: Icons.widgets_outlined,
      rows: _rows,
      cols: _cols,
      buttons: buttons,
      isCustom: true,
      photoPath: photoPath,
    );

    await ref.read(customAppliancesProvider.notifier).add(appliance);
    await ref.read(selectedApplianceProvider.notifier).select(appliance);

    // 서버에도 등록 — 키오스크가 이 가전을 받아 조작판에 띄운다.
    // 실패해도 폰에서는 이미 쓸 수 있으므로 막지 않고 알림만 남긴다.
    final rpiApi = ref.read(rpiApiServiceProvider);
    var synced = false;
    if (rpiApi != null) {
      synced = await rpiApi.registerAppliance(appliance);
    }
    if (mounted) {
      if (!synced) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('가전을 저장했어요. 키오스크 연동은 서버 연결 후 다시 저장하면 돼요.'),
          ),
        );
      }
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('새 가전 추가')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: context.appPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.widgets_outlined, color: context.appPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '우리 집 가전의 버튼 배치를 그대로 등록하면\n어떤 가전이든 앱에서 바로 조작할 수 있어요.',
                  style: context.appCaption,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('가전 이름', style: AppText.title),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '예: 식기세척기',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('버튼 배치', style: AppText.title),
                  const SizedBox(height: 4),
                  Text(
                    '가전 사진을 찍으면 그 위에 격자를 겹쳐서 실제 버튼 위치를 보며 배치할 수 있어요.'
                    ' 사진 없이도 그대로 진행 가능해요.',
                    style: context.appCaption,
                  ),
                  const SizedBox(height: 10),
                  _photo == null
                      ? OutlinedButton.icon(
                          onPressed: _takePhoto,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('버튼 패널 사진 찍기'),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _takePhoto,
                                icon: const Icon(Icons.camera_alt_outlined),
                                label: const Text('다시 찍기'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: _removePhoto,
                              icon: const Icon(Icons.close),
                              tooltip: '사진 제거',
                            ),
                          ],
                        ),
                  const SizedBox(height: 4),
                  Text(
                    '버튼 패널이 화면에 꽉 차게 찍어주세요 — 격자가 사진 전체에 균등하게 겹쳐져요.',
                    style: context.appCaption,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _StepperField(
                          label: '행',
                          value: _rows,
                          min: _minGridSize,
                          max: _maxGridSize,
                          onChanged: (v) => _resize(rows: v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StepperField(
                          label: '열',
                          value: _cols,
                          min: _minGridSize,
                          max: _maxGridSize,
                          onChanged: (v) => _resize(cols: v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  AspectRatio(
                    aspectRatio: _cols / _rows,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_photo != null)
                            Image.file(_photo!, fit: BoxFit.cover),
                          _EditableGrid(
                            grid: _grid,
                            onTapCell: _editCell,
                            translucent: _photo != null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '음성 명령은 아직 지원되지 않아요 — 저장하면 화면에서 버튼을 직접\n눌러 실행할 수 있습니다.',
              textAlign: TextAlign.center,
              style: context.appCaption,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('저장'),
          ),
        ],
      ),
    );
  }
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            padding: EdgeInsets.only(bottom: y < rows - 1 ? 7 : 0),
            child: Row(
              children: List.generate(cols, (x) {
                final label = grid[y][x];
                final filled = label != null;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: x < cols - 1 ? 7 : 0),
                    child: GestureDetector(
                      key: ValueKey('grid_cell_${x}_$y'),
                      onTap: () => onTapCell(x, y),
                      child: Container(
                        decoration: BoxDecoration(
                          color: filled
                              ? context.appPrimary.withValues(
                                  alpha: translucent ? 0.28 : 0.14)
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
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: translucent ? Colors.white : context.appPrimary,
                                  shadows: translucent
                                      ? const [Shadow(blurRadius: 4, color: Colors.black)]
                                      : null,
                                ),
                              )
                            : (translucent
                                ? null
                                : Icon(Icons.add, size: 16, color: context.appOutline)),
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
