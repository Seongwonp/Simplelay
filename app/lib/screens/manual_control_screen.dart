import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

enum _CellState { idle, pending, success, failure }

// 음성 명령이 없는 사용자 정의 가전용 — 버튼을 직접 탭해서 POST /execute-buttons로
// 하나씩 실행한다. 백엔드가 동시 실행을 막기 때문에(409), 한 번에 버튼 하나만
// 보내고 결과가 올 때까지 나머지 버튼도 비활성화한다.
class ManualControlScreen extends ConsumerStatefulWidget {
  const ManualControlScreen({super.key});

  @override
  ConsumerState<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends ConsumerState<ManualControlScreen> {
  String? _pendingButtonId;
  String? _resultButtonId;
  bool? _resultSuccess;
  Timer? _resultClearTimer;

  @override
  void dispose() {
    _resultClearTimer?.cancel();
    super.dispose();
  }

  Future<void> _press(RpiApiService api, ApplianceButton button) async {
    if (_pendingButtonId != null) return; // 이미 실행 중 — 무시
    _resultClearTimer?.cancel();
    setState(() {
      _pendingButtonId = button.id;
      _resultButtonId = null;
      _resultSuccess = null;
    });

    bool success;
    try {
      final result = await api.executeButtons([button.label]);
      success = result.buttons.every((b) => b.success);
    } catch (_) {
      success = false;
    }

    if (!mounted) return;
    setState(() {
      _pendingButtonId = null;
      _resultButtonId = button.id;
      _resultSuccess = success;
    });
    _resultClearTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _resultButtonId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final appliance = ref.watch(selectedApplianceProvider);
    final api = ref.watch(rpiApiServiceProvider);

    return Scaffold(
      appBar: AppBar(title: Text('${appliance.name} 버튼 조작')),
      body: api == null
          ? _NoServerConfigured(onGoToSettings: () => context.push('/settings'))
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '버튼을 탭하면 실제 가전 버튼이 눌립니다.',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _ButtonGrid(
                      appliance: appliance,
                      pendingButtonId: _pendingButtonId,
                      resultButtonId: _resultButtonId,
                      resultSuccess: _resultSuccess,
                      onTap: (button) => _press(api, button),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _NoServerConfigured extends StatelessWidget {
  const _NoServerConfigured({required this.onGoToSettings});
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: AppColors.onSurfaceMuted, size: 40),
              const SizedBox(height: 12),
              const Text(
                'RPi 서버 URL을 먼저 설정해야 버튼을 직접 실행할 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: onGoToSettings, child: const Text('설정으로 이동')),
            ],
          ),
        ),
      );
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({
    required this.appliance,
    required this.pendingButtonId,
    required this.resultButtonId,
    required this.resultSuccess,
    required this.onTap,
  });

  final ApplianceMap appliance;
  final String? pendingButtonId;
  final String? resultButtonId;
  final bool? resultSuccess;
  final void Function(ApplianceButton) onTap;

  @override
  Widget build(BuildContext context) {
    final busy = pendingButtonId != null;
    return Column(
      children: List.generate(appliance.rows, (y) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: y < appliance.rows - 1 ? 8 : 0),
            child: Row(
              children: List.generate(appliance.cols, (x) {
                final btn = appliance.buttonAt(x, y);
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: x < appliance.cols - 1 ? 8 : 0),
                    child: btn == null
                        ? const SizedBox.shrink()
                        : _ButtonCell(
                            button: btn,
                            state: btn.id == pendingButtonId
                                ? _CellState.pending
                                : btn.id == resultButtonId
                                    ? (resultSuccess == true
                                        ? _CellState.success
                                        : _CellState.failure)
                                    : _CellState.idle,
                            onTap: busy ? null : () => onTap(btn),
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

class _ButtonCell extends StatelessWidget {
  const _ButtonCell({required this.button, required this.state, required this.onTap});

  final ApplianceButton button;
  final _CellState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (Color color, Widget? overlay) = switch (state) {
      _CellState.pending => (
          AppColors.primary,
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      _CellState.success => (AppColors.success, const Icon(Icons.check, size: 18)),
      _CellState.failure => (AppColors.danger, const Icon(Icons.close, size: 18)),
      _CellState.idle => (Colors.white24, null),
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: state == _CellState.idle
              ? Colors.white.withValues(alpha: 0.05)
              : color.withValues(alpha: 0.16),
          border: Border.all(color: color, width: state == _CellState.idle ? 1 : 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: overlay ??
            Text(
              button.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: state == _CellState.idle ? Colors.white70 : color,
              ),
            ),
      ),
    );
  }
}
