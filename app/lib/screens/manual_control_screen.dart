import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../providers/execution_status_provider.dart';
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
  ConsumerState<ManualControlScreen> createState() =>
      _ManualControlScreenState();
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

  Future<void> _press(
    RpiApiService api,
    ApplianceButton button,
    String applianceId,
  ) async {
    if (_pendingButtonId != null) return; // 이미 실행 중 — 무시
    _resultClearTimer?.cancel();
    setState(() {
      _pendingButtonId = button.id;
      _resultButtonId = null;
      _resultSuccess = null;
    });

    bool success;
    try {
      // job 모델: 접수 즉시 job_id가 오고, 완료는 /status 폴링으로 판정한다.
      final accepted = await api.executeButtons(
        [button.label],
        applianceId: applianceId,
      );
      // 공용 실행 상태에 등록한다. 이 화면을 떠나도 상태 탭이 진행을
      // 이어서 보여주고, 무엇보다 **정지 수단이 유지된다** -- 예전에는
      // 여기서만 추적해서, 뒤로 나가면 실제 작업은 도는데 상태 탭은
      // 대기로 보이고 멈출 방법이 없었다.
      ref.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: accepted.jobId,
            label: button.label,
            steps: [button.label],
          );
      success = await _waitJobDone(api, accepted.jobId);
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

  // 내 job이 끝날 때까지 /status를 폴링한다. 버튼 1개 실행은 재시도를
  // 포함해도 수십 초 안에 끝나므로 45초를 상한으로 두고, 그 안에 판정이
  // 안 나면(서버 유실 등) 실패로 처리해 pending 잠금에서 탈출한다.
  Future<bool> _waitJobDone(RpiApiService api, String jobId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (mounted && DateTime.now().isBefore(deadline)) {
      try {
        final status = await api.status();
        // running 여부와 무관하게 lastJobId로 판정 — 완료 직후 다른
        // 클라이언트의 새 실행이 시작돼도(running=true) 내 결과를 놓치지 않는다
        if (status.lastJobId == jobId) {
          return status.lastStatus == 'succeeded';
        }
      } catch (_) {
        // 일시적 통신 오류는 다음 폴링에서 재시도
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final appliance = ref.watch(selectedApplianceProvider);
    final api = ref.watch(rpiApiServiceProvider);
    final photoPath = appliance.photoPath;
    final hasPhoto = photoPath != null && File(photoPath).existsSync();

    return Scaffold(
      appBar: AppBar(title: Text('${appliance.name} 버튼 조작')),
      body: api == null
          ? _NoServerConfigured(onGoToSettings: () => context.push('/settings'))
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 이 가전이 아직 준비 안 됐으면 **여기서 먼저 말한다.**
                  // 눌러 보고 나서 실패로 알게 되면, 실제로는 서버가
                  // 막았는데 사용자는 가전이 고장 난 줄 안다.
                  if (!appliance.canExecute)
                    _NotReadyNotice(appliance: appliance)
                  else
                    Row(
                      children: [
                        Icon(Icons.touch_app,
                            color: context.appPrimary, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '버튼을 탭하면 실제 가전 버튼이 눌립니다.',
                            style: context.appCaption,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: _PhotoBackedGrid(
                        appliance: appliance,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: _ButtonGrid(
                            appliance: appliance,
                            pendingButtonId: _pendingButtonId,
                            resultButtonId: _resultButtonId,
                            resultSuccess: _resultSuccess,
                            onPhoto: hasPhoto,
                            // 준비 안 된 가전은 탭 자체를 막는다. 서버도
                            // 412로 거절하지만(이중 방어), 누를 수 있는데
                            // 안 되는 버튼을 두면 사용자가 원인을 가전
                            // 쪽에서 찾게 된다.
                            onTap: appliance.canExecute
                                ? (button) => _press(api, button, appliance.id)
                                : null,
                          ),
                        ),
                      ),
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
              Icon(Icons.wifi_off,
                  color: context.appMuted, size: 40),
              const SizedBox(height: 12),
              Text(
                'RPi 서버 URL을 먼저 설정해야 버튼을 직접 실행할 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.appMuted),
              ),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: onGoToSettings, child: const Text('설정으로 이동')),
            ],
          ),
        ),
      );
}

/// 아직 맡길 수 없는 가전임을 화면 위쪽에서 알린다.
///
/// 상태 이름만 말하지 않고 **무엇이 남았는지**를 함께 낸다 — '안 됩니다'만
/// 알리면 사용자가 할 수 있는 일이 없다.
class _NotReadyNotice extends StatelessWidget {
  const _NotReadyNotice({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) {
    final disconnected = appliance.readiness == 'disconnected';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.appWarning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appWarning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            disconnected ? Icons.link_off : Icons.build_outlined,
            color: context.appWarning,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  disconnected ? '아직 연결되지 않았어요' : '아직 준비가 끝나지 않았어요',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (appliance.readinessReasons.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    appliance.readinessReasons.join(' · '),
                    style: TextStyle(color: context.appMuted, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// 등록 때 찍어둔 버튼 패널 사진이 있으면 그리드 뒤에 깔아준다 — 사용자가
// 실제 가전 버튼 배치를 눈으로 확인하며 누를 수 있다. 사진 파일이 지워졌으면
// 조용히 사진 없는 그리드로 폴백.
class _PhotoBackedGrid extends StatelessWidget {
  const _PhotoBackedGrid({required this.appliance, required this.child});

  final ApplianceMap appliance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final path = appliance.photoPath;
    if (path == null || !File(path).existsSync()) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(path), fit: BoxFit.cover),
        // 사진 위 가독성용 어두운 스크림 — 셀은 onPhoto 팔레트(흰색 계열)를 쓴다
        ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
        child,
      ],
    );
  }
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({
    required this.appliance,
    required this.pendingButtonId,
    required this.resultButtonId,
    required this.resultSuccess,
    required this.onTap,
    this.onPhoto = false,
  });

  final ApplianceMap appliance;
  final String? pendingButtonId;
  final String? resultButtonId;
  final bool? resultSuccess;
  /// null이면 이 가전은 아직 맡길 수 없다 (준비 미완).
  final void Function(ApplianceButton)? onTap;

  /// 사진 배경(어두운 스크림) 위에 그려지는 중 — 테마와 무관하게 흰색 계열 사용
  final bool onPhoto;

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
                    padding:
                        EdgeInsets.only(right: x < appliance.cols - 1 ? 8 : 0),
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
                            onPhoto: onPhoto,
                            onTap: (busy || onTap == null)
                                ? null
                                : () => onTap!(btn),
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
  const _ButtonCell({
    required this.button,
    required this.state,
    required this.onTap,
    this.onPhoto = false,
  });

  final ApplianceButton button;
  final _CellState state;
  final VoidCallback? onTap;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    // 사진 스크림(어두움) 위에서는 테마와 무관하게 흰색 계열이 맞다 —
    // 라이트 테마 토큰(검정 계열)을 쓰면 사진 위에서 안 보인다.
    final idleOutline = onPhoto ? Colors.white38 : context.appOutline;
    final idleFill = onPhoto
        ? Colors.white.withValues(alpha: 0.10)
        : context.appOverlayFaint;
    final idleText = onPhoto ? Colors.white : context.appOnSurfaceSoft;

    final (Color color, Widget? overlay) = switch (state) {
      _CellState.pending => (
          context.appPrimary,
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      _CellState.success => (
          context.appSuccess,
          const Icon(Icons.check, size: 18)
        ),
      _CellState.failure => (
          context.appDanger,
          const Icon(Icons.close, size: 18)
        ),
      _CellState.idle => (idleOutline, null),
    };

    // Material+InkWell: 탭 시 잉크 피드백(눌렸는지 눈으로 확인 가능) +
    // 스크린리더에 버튼으로 인식. 물리 버튼을 누르는 앱 특성상 탭 순간
    // 햅틱도 함께 준다 — 시각에 의존하지 않는 확인 채널.
    return Semantics(
      button: true,
      enabled: onTap != null,
      // 셀 상태(대기·실행 중·성공·실패)가 색으로만 구분돼 스크린리더에는
      // 라벨만 전달됐다 — 무엇이 눌리는 중인지 알 수 없었다.
      label: switch (state) {
        _CellState.idle => '${button.label} 버튼 누르기',
        _CellState.pending => '${button.label} 누르는 중',
        _CellState.success => '${button.label} 눌림 확인됨',
        _CellState.failure => '${button.label} 실패',
      },
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: state == _CellState.idle
                ? idleFill
                : color.withValues(alpha: 0.16),
            border: Border.all(
                color: color, width: state == _CellState.idle ? 1 : 1.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onTap!();
                  },
            child: Center(
              child: overlay ??
                  Text(
                    button.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: state == _CellState.idle ? idleText : color,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
