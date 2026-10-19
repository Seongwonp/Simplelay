import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/line_break.dart';
import '../models/routine.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';

/// 다음 루틴 '오늘은 건너뛰기' / '되돌리기' 단추 하나(사용자 결정 2026-10-18) — 홈 '지금 우리 집'의 다음 예정 줄과
/// 루틴 탭의 '다음' 줄이 같은 것을 쓴다.
///
/// - 단추 말은 본체가 준 `skip_action_label` 그대로(폰이 날짜 말을 만들지 않는다). 건너뛴 뒤의 '오늘은 건너뛰어요'
///   표시는 둘레(배지·줄 표시)가 말하고, 여기는 '되돌리기'만 둔다.
/// - 확인 창은 없다 — 되돌리기가 바로 옆에 있다. 응답을 기다리는 동안 두 번째 탭은 버린다.
/// - 성공하면 다음 예정을 다시 받아 둘레와 함께 바뀐다. 실패면 본체 문장을 스낵바로, 409면 다음 예정을 다시 받는다.
/// - 건너뛰기는 실행·정지 경로와 무관하다(지금 하는 일을 멈추지 않는다 — 정지는 실행 바).
class SkipNextControl extends ConsumerStatefulWidget {
  const SkipNextControl({super.key, required this.next});

  final RoutineNextRun next;

  @override
  ConsumerState<SkipNextControl> createState() => _SkipNextControlState();
}

class _SkipNextControlState extends ConsumerState<SkipNextControl> {
  bool _busy = false;

  Future<void> _toggle() async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null || _busy) return;
    final run = widget.next;
    final undo = run.skipped;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String? failure;
    var reload = true;
    try {
      if (undo) {
        await api.unskipNextRoutine(run);
      } else {
        await api.skipNextRoutine(run);
      }
    } on RpiApiException catch (e) {
      failure = e.message.trim().isNotEmpty && e.statusCode < 500 ? e.message : null;
      failure ??= undo ? '되돌리지 못했어요. 연결을 보고 다시 해 주세요.' : '건너뛰지 못했어요. 연결을 보고 다시 해 주세요.';
      // 409(지났거나 다음 회차가 바뀜)만 다시 받는다 — 다른 실패는 화면을 그대로 둔다.
      reload = e.statusCode == 409;
    } catch (_) {
      failure = undo ? '되돌리지 못했어요. 연결을 보고 다시 해 주세요.' : '건너뛰지 못했어요. 연결을 보고 다시 해 주세요.';
      reload = false;
    }
    try {
      if (reload && mounted) {
        // 다시 받을 때까지 단추를 잠가 둔다 — 옛 값으로 한 번 더 누르지 않게.
        ref.invalidate(nextRoutineProvider);
        await ref.read(nextRoutineProvider.future);
      }
    } catch (_) {
      // 다시 받기 실패는 다음 새로고침에 맡긴다.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (failure != null) messenger.showSnackBar(SnackBar(content: Text(failure)));
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.next;
    if (!n.canSkip || ref.watch(rpiApiServiceProvider) == null) return const SizedBox.shrink();
    final undo = n.skipped;
    final label = undo ? '되돌리기' : n.skipActionLabel;
    final semantic = undo ? '${n.name} 건너뛰기 되돌리기' : '${n.name} ${n.skipActionLabel}';
    // '되돌리기'는 작은 회색 굵은 글자만(10/19) — 건너뛴 표시가 이미 말하므로 눈에 덜 띄게. '오늘은 건너뛰기'는 그대로.
    final color = _busy || undo ? context.appMuted : context.appInk;
    return Semantics(
      label: semantic,
      button: true,
      enabled: !_busy,
      container: true,
      excludeSemantics: true,
      child: InkWell(
        key: Key('${undo ? 'unskip' : 'skip'}-next-${n.routineId}'),
        borderRadius: BorderRadius.circular(8),
        onTap: _busy ? null : _toggle,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            // 왼쪽은 비우지 않는다 — 아이콘이 위 글 줄(이름·언제)의 시작과 맞는다.
            padding: const EdgeInsets.only(right: AppSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy)
                  const SizedBox(
                    width: AppSpace.lg,
                    height: AppSpace.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (!undo)
                  Icon(AppIcons.skipOnce, size: AppSpace.xl, color: context.appMuted),
                if (_busy || !undo) const SizedBox(width: AppSpace.sm),
                Flexible(
                  child: Text(
                    keepWordsTogether(label),
                    semanticsLabel: label,
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
