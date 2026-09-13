part of '../settings_screen.dart';

// ── 가전 선택 ─────────────────────────────────────────────────────────────

class _ApplianceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedApplianceProvider);
    // 여기는 **이 폰에 설치된 가전**만 고른다. 예시 템플릿을 섞으면 아직
    // 아무것도 등록하지 않은 사람에게 전자레인지가 이미 있는 것처럼 보인다.
    final appliances = ref.watch(installedAppliancesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('제어 가전'),
        const SizedBox(height: 10),
        // 0대는 오류가 아니다. 고를 것이 없다는 사실과 어디서 만드는지만
        // 말하고, 선택 칩 자리를 비워 두지 않는다.
        if (appliances.isEmpty)
          _EmptyApplianceRow(onAdd: () => context.push('/appliance/new'))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...appliances.map((appliance) {
                final isSelected = appliance.id == selected?.id;
                // 선택 상태를 시맨틱으로 노출한다 -- 체크 아이콘은 눈으로만
                // 보이는 신호라, 스크린리더 사용자는 가전 이름은 읽어도
                // 무엇이 선택됐는지 알 수 없었다.
                return Semantics(
                  button: true,
                  selected: isSelected,
                  child: GestureDetector(
                    onTap: () => ref
                        .read(selectedApplianceProvider.notifier)
                        .select(appliance),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      // 터치 목표 하한. 고령 사용자 대상이라 WCAG 2.2 AA의
                      // 최소치(24)보다 높은 48을 제품 기준으로 잡는다.
                      constraints: const BoxConstraints(minHeight: 48),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? context.appPrimary.withValues(alpha: 0.14)
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? context.appPrimary
                              : context.appBorderSubtle,
                          width: isSelected ? 1.5 : 0.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            appliance.icon,
                            color: isSelected
                                ? context.appPrimary
                                : context.appMuted,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            appliance.displayName,
                            style: TextStyle(
                              fontSize: 13,
                              color: isSelected
                                  ? context.appPrimary
                                  : context.appMuted,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (isSelected) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.check_circle,
                                color: context.appPrimary, size: 14),
                          ],
                          if (appliance.isCustom) ...[
                            const SizedBox(width: 2),
                            // 등록 데이터(버튼맵·사진)가 즉시 유실되는 파괴적
                            // 동작 — 반드시 확인을 거친다. 히트박스도 14px
                            // 아이콘 단독이 아니라 패딩 포함으로 확대.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _confirmRemoveAppliance(
                                  context, ref, appliance),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(Icons.close,
                                    color: context.appMuted, size: 14),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }),
              // 새 가전 추가 버튼
              GestureDetector(
                onTap: () => context.push('/appliance/new'),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: context.appBorderSubtle, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, color: context.appMuted, size: 18),
                      const SizedBox(width: 6),
                      Text('새 가전',
                          style:
                              TextStyle(fontSize: 13, color: context.appMuted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        // 아직 키오스크에 못 보낸 변경이 있으면 **여기서 먼저 말한다.**
        // 평상시에는 아무것도 띄우지 않는다 -- 늘 떠 있는 상태 표시는
        // 읽히지 않고, 정작 문제가 생겼을 때도 눈에 안 들어온다.
        SyncStatusLine(onRetry: () => _resyncCustomAppliances(context, ref)),
        if (ref.watch(hasPendingSyncProvider)) ...[
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => _resyncCustomAppliances(context, ref),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: Icon(Icons.sync, size: 18, color: context.appMuted),
            label: Text(
              '키오스크와 다시 동기화',
              style: TextStyle(fontSize: 13, color: context.appMuted),
            ),
          ),
        ],
      ],
    );
  }

  /// 양방향 동기화. **다른 폰이 등록한 가전을 지우지 않는다** — 서버에만
  /// 있다는 것은 "지워도 된다"가 아니라 "이 폰이 아직 못 받았다"는 뜻이다.
  Future<void> _resyncCustomAppliances(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(rpiApiServiceProvider) == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('서버 주소를 먼저 설정해 주세요.')),
      );
      return;
    }
    // 이 버튼은 복구 수단이다 — 대기열에 없던 가전(서버가 꺼져 있던 시절에
    // 등록한 것)까지 다시 올린다.
    final result = await ref.read(applianceSyncProvider.notifier).resendAll();
    messenger.showSnackBar(SnackBar(content: Text(_syncMessage(result))));
  }

  /// 사용자 문구에는 내부 용어(upsert·tombstone·revision·409)를 쓰지 않는다.
  static String _syncMessage(ApplianceSyncResult r) {
    if (r.conflicts > 0) {
      // 자동으로 덮어쓰지 않았다는 것을 분명히 말한다.
      return '다른 기기에서 변경되어 서버 내용을 가져왔어요.';
    }
    if (r.allDone) {
      final parts = [
        if (r.sent > 0) '보냄 ${r.sent}건',
        if (r.adopted > 0) '새로 받음 ${r.adopted}개',
      ];
      return parts.isEmpty
          ? '이미 키오스크와 같은 상태예요.'
          : '동기화했어요 — ${parts.join(' · ')}.';
    }
    if (r.failed > 0) {
      return '변경 ${r.failed}건을 보내지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.';
    }
    return '키오스크 목록을 불러오지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.';
  }

  Future<void> _confirmRemoveAppliance(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap appliance,
  ) async {
    // async gap 전에 캡처 — 다이얼로그가 닫힌 뒤의 context 사용을 피한다
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('\'${appliance.name}\' 삭제'),
        content: const Text('등록한 버튼 배치와 사진이 함께 삭제됩니다. 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            // 전경색을 명시하지 않으면 라이트 모드에서 흰 글자(3.63:1)가 된다
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.onAccent,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // 폰 삭제는 무조건 성립하고(사용자가 지시한 일이다), 서버 전송이
      // 실패하면 그 사실이 삭제 대기열에 남아 다음 동기화가 다시 보낸다.
      // 예전에는 실패를 스낵바로만 알리고 잊어서, 복구가 "서버에만 있는
      // 건 다 지운다"는 위험한 방식에 얹혀 있었다 (R3).
      final result = await ref
          .read(applianceSyncProvider.notifier)
          .deleteAppliance(appliance.id);
      if (result.failed > 0) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('폰에서는 삭제했어요. 키오스크 반영은 다음 동기화 때 '
                '다시 시도할게요.'),
          ),
        );
      }
    }
  }
}

/// 설치한 가전이 0대일 때 '제어 가전' 자리에 놓는 줄.
class _EmptyApplianceRow extends StatelessWidget {
  const _EmptyApplianceRow({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              '아직 추가한 가전이 없어요.',
              style: TextStyle(color: context.appMuted, fontSize: 13),
            ),
          ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('가전 추가'),
          ),
        ],
      );
}
