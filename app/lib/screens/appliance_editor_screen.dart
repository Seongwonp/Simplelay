import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
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
              child: const Text('삭제', style: TextStyle(color: AppColors.danger)),
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

    final appliance = ApplianceMap(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      icon: Icons.widgets_outlined,
      rows: _rows,
      cols: _cols,
      buttons: buttons,
      isCustom: true,
    );

    await ref.read(customAppliancesProvider.notifier).add(appliance);
    await ref.read(selectedApplianceProvider.notifier).select(appliance);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('새 가전 추가')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('가전 이름', style: AppText.title),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '예: 식기세척기',
            ),
          ),
          const SizedBox(height: 24),
          Text('버튼 배치', style: AppText.title),
          const SizedBox(height: 4),
          const Text(
            '행/열 크기를 정하고, 빈 칸을 탭해서 버튼을 추가하세요. 실제 가전의 버튼\n'
            '배치와 비슷하게 놓으면 나중에 화면에서 알아보기 쉽습니다.',
            style: AppText.caption,
          ),
          const SizedBox(height: 12),
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
            child: _EditableGrid(grid: _grid, onTapCell: _editCell),
          ),
          const SizedBox(height: 28),
          Text(
            '음성 명령은 아직 지원되지 않아요 — 저장하면 화면에서 버튼을 직접 눌러 실행할\n'
            '수 있습니다.',
            style: AppText.caption,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('저장'),
            ),
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
  const _EditableGrid({required this.grid, required this.onTapCell});

  final List<List<String?>> grid;
  final void Function(int x, int y) onTapCell;

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
                      onTap: () => onTapCell(x, y),
                      child: Container(
                        decoration: BoxDecoration(
                          color: filled
                              ? AppColors.primary.withValues(alpha: 0.14)
                              : Colors.white.withValues(alpha: 0.04),
                          border: Border.all(
                            color: filled ? AppColors.primary : AppColors.borderSubtle,
                            width: filled ? 1.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        alignment: Alignment.center,
                        child: filled
                            ? Text(
                                label,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary,
                                ),
                              )
                            : const Icon(Icons.add, size: 16, color: Colors.white24),
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
