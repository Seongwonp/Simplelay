part of '../settings_screen.dart';

/// 본체에 못 보낸 가전 변경을 다시 보내고 본체 쪽 목록도 받아 오는 버튼 — 쉬운 말('동기화' 대신, UI 평가 10/17).
/// 사용자가 얻는 것으로 이름 짓는다(평가 4차 10/18: '본체와 다시 맞추기'는 기계가 하는 일을 말했다).
const kResyncLabel = '가전 다시 불러오기';

/// 안부 알림을 며칠 쉬는 설정의 이름 — 하는 일 그대로(평가 3차 10/18, 예전 '안부 확인 쉬기').
const kAwayTitle = '집 비우는 날';

// ── 가전 선택 ─────────────────────────────────────────────────────────────

class _ApplianceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(installedAppliancesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (appliances.isEmpty)
          const Text('홈에서 가전을 추가해 주세요.'),
        // 홈과 같은 목록 — ThinQ 가전도 보인다(UI 평가 10/17: 홈 5대·설정 4대였다). 지울 수 없는 줄은 이유를
        // 부제로, 눌러서 들어간다는 것은 화살표로 말한다.
        for (final appliance in appliances)
          ListTile(
            leading: Icon(appliance.icon),
            title: Text(appliance.displayName),
            // 버튼 자리를 맞추지 않은 가전은 홈과 같은 안내(UI 평가 4차 10/17 — 홈에만 '설정이 필요해요'가 있었다).
            subtitle: appliance.isCustom && !appliance.isThinq
                ? (needsPanelMapping(appliance)
                    // 어절 단위 줄바꿈('버 / 튼' 방지, 실화면 10/17).
                    ? _WordsText('설정이 필요해요. 눌러서 버튼 자리를 맞춰 주세요',
                        style: TextStyle(fontSize: AppFont.caption, color: context.appWarning))
                    : null)
                // 평가 4차 10/18: '처음부터 들어 있는 가전이에요'·'빼기는 LG 가전 연결에서 해요'는 앱이 어떻게 만들어졌는지를
                // 말했다. 사용자가 할 일이 있을 때만 적는다 — LG 가전은 LG 앱에서 관리한다는 것, 그 밖은 비운다.
                : appliance.isThinq
                    ? _WordsText('LG 앱에서 관리해요',
                        style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
                    : null,
            onTap: () => context.push('/appliance/detail/${appliance.id}'),
            // 지울 수 있는 줄도 눌러 들어간다는 것은 화살표로(UI 평가 3차 10/17 — 휴지통만 있으면 눌러지는 줄과 섞였다).
            // 지우기는 행에 늘어놓지 않고 ⋮ 안(2026-10-18 버튼 위계). 확인 대화는 그대로.
            // 줄 끝 표시는 하나만(평가 5차 10/18: ⋮와 > 가 한 줄에 같이 있었다). 지울 수 있는 줄은 ⋮(줄을 누르면
            // 그대로 상세로 간다), 지울 수 없는 줄은 >.
            trailing: appliance.isCustom && !appliance.isThinq
                ? RowMenu(
                    menuKey: Key('appliance-menu-${appliance.id}'),
                    semanticLabel: '${appliance.name} 더 보기',
                    items: [
                      RowMenuItem(
                        key: Key('appliance-delete-${appliance.id}'),
                        label: '지우기',
                        icon: Icons.delete_outline,
                        danger: true,
                        onSelected: () => _confirmRemoveAppliance(context, ref, appliance),
                      ),
                    ],
                  )
                : Icon(Icons.chevron_right, color: context.appMuted),
          ),
        // 아직 키오스크에 못 보낸 변경이 있으면 **여기서 먼저 말한다.**
        // 평상시에는 아무것도 띄우지 않는다 -- 늘 떠 있는 상태 표시는
        // 읽히지 않고, 정작 문제가 생겼을 때도 눈에 안 들어온다.
        SyncStatusLine(onRetry: () => _resyncCustomAppliances(context, ref)),
        if (ref.watch(hasPendingSyncProvider)) ...[
          const SizedBox(height: AppSpace.md),
          TextButton.icon(
            onPressed: () => _resyncCustomAppliances(context, ref),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            ),
            icon: Icon(Icons.sync, size: 18, color: context.appMuted),
            label: Text(
              kResyncLabel,
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ),
        ],
        // 서버가 구성한 ThinQ 가전(편집 불가). ThinQ가 꺼져 있으면 아무것도 없다.
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
        const SnackBar(content: Text('본체 주소를 먼저 넣어 주세요.')),
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
      return '다른 폰에서 바꾼 것이 있어 본체 내용으로 맞췄어요.';
    }
    if (r.allDone) {
      final parts = [
        if (r.sent > 0) '${r.sent}건 보냈어요',
        if (r.adopted > 0) '${r.adopted}개 새로 받았어요',
      ];
      return parts.isEmpty
          ? '이미 새 목록이에요.'
          : '가전 목록을 새로 받았어요. ${parts.join(', ')}.';
    }
    if (r.failed > 0) {
      return '바꾼 것 ${r.failed}건을 보내지 못했어요. 연결을 보고 다시 해 주세요.';
    }
    return '본체 목록을 불러오지 못했어요. 연결을 보고 다시 해 주세요.';
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
        content: const Text('등록한 버튼 배치와 사진이 함께 삭제돼요. 삭제할까요?'),
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
            content: Text('폰에서는 지웠어요. 본체에는 다음에 맞출 때 '
                '다시 시도할게요.'),
          ),
        );
      }
    }
  }
}

/// 설치한 가전이 0대일 때 '제어 가전' 자리에 놓는 줄.
class _ThinqApplianceList extends ConsumerWidget {
  const _ThinqApplianceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(thinqOverviewProvider).valueOrNull;
    if (overview == null || overview.appliances.isEmpty) {
      return const SizedBox.shrink();
    }
    final mock = overview.executionMode == 'mock';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mock ? 'LG 가전. 연습으로 연결돼 있어요' : 'LG 가전'),
          const SizedBox(height: AppSpace.sm),
          for (final a in overview.appliances)
            Semantics(
              label: [
                a.name,
                'LG 가전',
                if (mock) '연습',
                a.canExecute ? '쓸 수 있어요' : '지금은 못 써요',
                ...a.reasons,
              ].join('. '),
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        a.canExecute
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 20,
                        color: a.canExecute
                            ? context.appSuccess
                            : context.appDanger,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${a.name}${mock ? ', 연습' : ''}',
                              style: const TextStyle(
                                  fontSize: AppFont.caption, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              a.canExecute
                                  ? '쓸 수 있어요'
                                  : (a.reasons.isNotEmpty
                                      ? a.reasons.join(', ')
                                      : '아직 준비가 안 됐어요'),
                              style: TextStyle(
                                fontSize: AppFont.caption,
                                color: a.canExecute
                                    ? context.appMuted
                                    : context.appDanger,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
