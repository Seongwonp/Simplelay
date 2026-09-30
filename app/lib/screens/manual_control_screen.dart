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
import '../widgets/appliance_portrait.dart';
import '../widgets/demo_badge.dart';
import '../widgets/no_appliance_notice.dart';
import '../widgets/route_badge.dart';

enum _CellState { idle, pending, success, failure }

/// 버튼을 직접 눌러 하나씩 실행한다 -- 말로 시키기 어려운 사용자의 다른 길.
///
/// 읽는 순서: 어느 가전인가(사진/실루엣 + 이름) → 지금 눌러도 되는가 →
/// 방금 누른 결과 → 버튼판. 결과는 셀 색만으로 말하지 않고 문장으로도
/// 말한다. 백엔드가 동시 실행을 막기 때문에(409) 한 번에 하나만 보내고,
/// 결과가 올 때까지 나머지 버튼도 잠근다.
class ManualControlScreen extends ConsumerStatefulWidget {
  const ManualControlScreen({super.key});

  @override
  ConsumerState<ManualControlScreen> createState() =>
      _ManualControlScreenState();
}

class _ManualControlScreenState extends ConsumerState<ManualControlScreen> {
  String? _pendingButtonId;
  String? _pendingLabel;
  String? _resultButtonId;
  String? _resultLabel;
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
      _pendingLabel = button.label;
      _resultButtonId = null;
      _resultLabel = null;
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
      _pendingLabel = null;
      _resultButtonId = button.id;
      _resultLabel = button.label;
      _resultSuccess = success;
    });
    // 셀의 색은 2초 뒤 거둔다. 문장은 다음 버튼을 누를 때까지 남긴다 --
    // 실패를 2초 만에 지우면 한눈판 사람은 무슨 일이 있었는지 모른다.
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

    // 조작할 가전이 없으면 **빈 조작판을 그리지 않는다.**
    //
    // 버튼 0개짜리 격자는 "고장 났다"로 읽힌다. 격자가 비어 있는 이유가
    // 가전이 없어서라는 사실과, 그걸 어디서 해결하는지를 대신 말한다.
    if (appliance == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('버튼 조작')),
        body: NoApplianceNotice(
          title: '조작할 가전이 아직 없어요',
          body: '가전을 추가하면 버튼 배치를 그대로 눌러 볼 수 있어요.',
          onAdd: () => context.push('/appliance/add'),
        ),
      );
    }

    // ThinQ 가전에는 누를 버튼이 없다(G5). 빈 격자를 그리면 고장으로
    // 읽힌다 -- 경로를 밝히고 말(목적) 경로로 보낸다.
    if (appliance.isThinq) {
      return Scaffold(
        appBar: AppBar(title: const Text('버튼 조작')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            _TargetHeader(appliance: appliance),
            const SizedBox(height: 20),
            Text(
              '이 가전은 ThinQ로 조작해요. 누를 버튼이 없어요.',
              style: AppText.title,
            ),
            const SizedBox(height: 6),
            Text(
              '말로 맡기거나 제안을 승인해 주세요.',
              style: TextStyle(fontSize: 15, color: context.appMuted),
            ),
          ],
        ),
      );
    }

    final api = ref.watch(rpiApiServiceProvider);
    if (api == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('버튼 조작')),
        body: _NotConnected(onGoToSettings: () => context.push('/settings')),
      );
    }

    final photoPath = appliance.photoPath;
    final hasPhoto = photoPath != null && File(photoPath).existsSync();
    final busy = _pendingButtonId != null;

    return Scaffold(
      appBar: AppBar(title: const Text('버튼 조작')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          // ── 어느 가전인가 ────────────────────────────────────────────────
          _TargetHeader(appliance: appliance),

          const SizedBox(height: 16),

          // ── 지금 눌러도 되는가 ───────────────────────────────────────────
          // 이 가전이 아직 준비 안 됐으면 **여기서 먼저 말한다.** 눌러 보고
          // 나서 실패로 알게 되면, 실제로는 서버가 막았는데 사용자는 가전이
          // 고장 난 줄 안다.
          if (!appliance.canExecute)
            _NotReadyNotice(appliance: appliance)
          else
            _FeedbackLine(
              pendingLabel: _pendingLabel,
              resultLabel: _resultLabel,
              resultSuccess: _resultSuccess,
              onSeeStatus: () => context.go('/status'),
            ),

          const SizedBox(height: 20),

          // ── 버튼판 ──────────────────────────────────────────────────────
          // 등록 때 찍은 사진이 있으면 그 위에 격자를 겹친다 -- 실제 배치를
          // 눈으로 확인하며 누른다. 사진이 없으면 격자만, 카드 없이.
          // 준비 안 된 가전의 버튼판은 흐리게 -- 위 안내와 같은 말을 모양으로도
          // 한다. 눌리는 판과 똑같이 보이면 안내를 못 본 사람이 눌러 본다.
          Opacity(
            opacity: appliance.canExecute ? 1 : 0.45,
            child: _PhotoBackedGrid(
              appliance: appliance,
              hasPhoto: hasPhoto,
              child: _ButtonGrid(
                appliance: appliance,
                fill: hasPhoto,
                pendingButtonId: _pendingButtonId,
                resultButtonId: _resultButtonId,
                resultSuccess: _resultSuccess,
                onPhoto: hasPhoto,
                // 준비 안 된 가전은 탭 자체를 막는다. 서버도 412로
                // 거절하지만(이중 방어), 누를 수 있는데 안 되는 버튼을
                // 두면 사용자가 원인을 가전 쪽에서 찾게 된다.
                onTap: appliance.canExecute && !busy
                    ? (button) => _press(api, button, appliance.id)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 어느 가전인가 ────────────────────────────────────────────────────────

class _TargetHeader extends StatelessWidget {
  const _TargetHeader({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          AppliancePortrait(appliance: appliance, size: 64, borderRadius: 12),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(appliance.displayName, style: AppText.title),
                    ),
                    if (appliance.isDemo) ...[
                      const SizedBox(width: 8),
                      const DemoBadge(),
                    ],
                    if (appliance.isThinq) ...[
                      const SizedBox(width: 8),
                      const RouteBadge(label: 'ThinQ'),
                    ],
                  ],
                ),
                if (!appliance.isThinq) ...[
                  const SizedBox(height: 4),
                  Text(
                    '버튼 ${appliance.buttons.length}개 · 누르면 실제 가전 버튼이 눌려요',
                    style: TextStyle(fontSize: 15, color: context.appMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
}

// ── 방금 누른 결과 ────────────────────────────────────────────────────────

/// 셀 색만으로 말하지 않는다. 무엇을 눌렀고 어떻게 됐는지 문장으로 남기고,
/// 실패했으면 실행 상태(정지·재확인이 있는 곳)로 가는 길을 둔다.
class _FeedbackLine extends StatelessWidget {
  const _FeedbackLine({
    required this.pendingLabel,
    required this.resultLabel,
    required this.resultSuccess,
    required this.onSeeStatus,
  });

  final String? pendingLabel;
  final String? resultLabel;
  final bool? resultSuccess;
  final VoidCallback onSeeStatus;

  @override
  Widget build(BuildContext context) {
    if (pendingLabel != null) {
      return Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text("'$pendingLabel' 누르는 중…",
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    }
    if (resultLabel != null && resultSuccess != null) {
      final ok = resultSuccess!;
      return Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 22,
            color: ok ? context.appSuccess : context.appDanger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ok ? "'$resultLabel' 눌림을 확인했어요" : "'$resultLabel' 눌림을 확인하지 못했어요",
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: ok ? context.appSuccess : context.appDanger,
              ),
            ),
          ),
          if (!ok)
            TextButton(
              onPressed: onSeeStatus,
              child: const Text('자세히'),
            ),
        ],
      );
    }
    return Row(
      children: [
        Icon(Icons.touch_app, color: context.appMuted, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '누를 버튼을 고르세요. 한 번에 하나씩 눌러요.',
            style: TextStyle(fontSize: 15, color: context.appMuted),
          ),
        ),
      ],
    );
  }
}

// ── 연결 안 됨 ───────────────────────────────────────────────────────────

/// 버튼을 대신 눌러 줄 기기와 아직 이어지지 않았다. 내부 이름(RPi·URL)을
/// 사용자에게 말하지 않는다 -- 무엇이 없고 어디서 하면 되는지만.
class _NotConnected extends StatelessWidget {
  const _NotConnected({required this.onGoToSettings});
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, color: context.appMuted, size: 52),
              const SizedBox(height: 18),
              Text(
                '버튼을 대신 눌러 줄 기기와 아직 연결되지 않았어요',
                textAlign: TextAlign.center,
                style: AppText.title,
              ),
              const SizedBox(height: 8),
              Text(
                '설정에서 연결 주소를 입력하면 여기서 바로 누를 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: context.appMuted),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onGoToSettings,
                icon: const Icon(Icons.settings, size: 20),
                label: const Text('설정으로 이동'),
              ),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          disconnected ? Icons.link_off : Icons.build_outlined,
          color: context.appWarning,
          size: 22,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                disconnected ? '아직 연결되지 않았어요' : '아직 준비가 끝나지 않았어요',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: context.appWarning,
                ),
              ),
              if (appliance.readinessReasons.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  appliance.readinessReasons.join(' · '),
                  style: TextStyle(color: context.appMuted, fontSize: 15),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── 버튼판 ───────────────────────────────────────────────────────────────

/// 등록 때 찍어둔 버튼 패널 사진이 있으면 그리드 뒤에 깔아준다 — 사용자가
/// 실제 가전 버튼 배치를 눈으로 확인하며 누를 수 있다. 사진 파일이
/// 지워졌으면 사진 없는 그리드로 폴백.
class _PhotoBackedGrid extends StatelessWidget {
  const _PhotoBackedGrid({
    required this.appliance,
    required this.hasPhoto,
    required this.child,
  });

  final ApplianceMap appliance;
  final bool hasPhoto;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasPhoto) return child;
    // 사진 위에 겹치려면 격자에 크기를 줘야 한다. 세로 사진이 대부분이라
    // 3:4로 잡고, 그 안을 격자가 채운다.
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(appliance.photoPath!), fit: BoxFit.cover),
            // 사진 위 가독성용 어두운 스크림 — 셀은 onPhoto 팔레트(흰색 계열)
            ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
            Padding(padding: const EdgeInsets.all(12), child: child),
          ],
        ),
      ),
    );
  }
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({
    required this.appliance,
    required this.fill,
    required this.pendingButtonId,
    required this.resultButtonId,
    required this.resultSuccess,
    required this.onTap,
    this.onPhoto = false,
  });

  final ApplianceMap appliance;

  /// 주어진 높이를 채운다(사진 위). 아니면 셀마다 고정 최소 높이.
  final bool fill;
  final String? pendingButtonId;
  final String? resultButtonId;
  final bool? resultSuccess;

  /// null이면 지금은 누를 수 없다(준비 미완·실행 중).
  final void Function(ApplianceButton)? onTap;

  /// 사진 배경(어두운 스크림) 위에 그려지는 중 — 테마와 무관하게 흰색 계열 사용
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    Widget row(int y) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        onPhoto: onPhoto,
                        onTap: onTap == null ? null : () => onTap!(btn),
                      ),
              ),
            );
          }),
        );

    return Column(
      children: List.generate(appliance.rows, (y) {
        final gap = y < appliance.rows - 1 ? 8.0 : 0.0;
        if (fill) {
          return Expanded(
            child:
                Padding(padding: EdgeInsets.only(bottom: gap), child: row(y)),
          );
        }
        // 한 줄의 높이는 그 줄에서 가장 긴 라벨이 정한다 -- 큰 글씨에서
        // 라벨이 잘리지 않는다. 최소 높이는 셀이 정한다.
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: IntrinsicHeight(child: row(y)),
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
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      _CellState.success => (
          context.appSuccess,
          const Icon(Icons.check, size: 22)
        ),
      _CellState.failure => (
          context.appDanger,
          const Icon(Icons.close, size: 22)
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
          // 고령 사용자 기준 터치 목표. 48이 하한이지만 실제 가전 버튼을
          // 대신 누르는 자리라 더 넉넉히 잡는다.
          constraints: const BoxConstraints(minHeight: 72),
          decoration: BoxDecoration(
            color: state == _CellState.idle
                ? idleFill
                : color.withValues(alpha: 0.16),
            border: Border.all(
                color: color, width: state == _CellState.idle ? 1 : 2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onTap!();
                  },
            child: Center(
              child: overlay ??
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Text(
                      button.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: state == _CellState.idle ? idleText : color,
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
