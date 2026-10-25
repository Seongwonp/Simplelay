part of '../settings_screen.dart';

/// 본체에 못 보낸 가전 변경을 다시 보내고 본체 쪽 목록도 받아 오는 버튼 — 쉬운 말('동기화' 대신, UI 평가 10/17).
/// 사용자가 얻는 것으로 이름 짓는다(평가 4차 10/18: '본체와 다시 맞추기'는 기계가 하는 일을 말했다).
/// 평가 11차(10/18): '가전 다시 불러오기'는 무엇이 일어나는지 모호했다 — 이 단추는 본체에 못 보낸 변경이 있을 때만 뜨고,
/// 이 폰에서 바꾼 가전을 본체로 다시 보낸다(본체에만 있는 가전은 받아 오되 지우지 않는다). 하는 일 그대로.
/// 평가 12차(10/18): '다시 보내기'는 여전히 동기화(기계가 하는 일)였다 → 사용자가 얻는 결과로. 단추는 이 폰에서 바꾼
/// 가전이 본체에 아직 없을 때만 뜬다([hasPendingSyncProvider]).
const kResyncLabel = '본체에도 똑같이 맞추기';

/// 본체에 저장된 내용과 달라 이 폰 변경을 보내지 않고 본체 내용으로 맞췄을 때. 다른 폰이 없어도 생긴다(키오스크에서
/// 다시 맞추기·본체 판 번호만 바뀜 등) — '다른 폰에서 바꾼 것이 있어'라고 하지 않는다(검토 10/19).
const kSyncConflictMessage = '본체에 저장된 내용과 달라서 본체 내용으로 맞췄어요.';

/// LG 가전 줄 부제(평가 12차 10/18).
/// 평가 17차(10/18): '켜기·끄기는 여기서 / 등록은 LG 앱에서' 토막말 두 줄 → 할 일 한 문장. 켜기·끄기는 줄을 눌러
/// 들어간 상태 카드에서 한다(줄 끝 >가 말한다).
const kThinqSubtitleLines = ['등록은 LG 앱에서 해요'];

/// 연습 LG 가전 줄 부제(보호자 과업 평가 10/18).
const kPracticeSubtitle = '연습용이라 등록할 필요 없어요';

/// 안부 알림을 며칠 쉬는 설정의 이름 — 하는 일 그대로(평가 3차 10/18, 예전 '안부 확인 쉬기').
const kAwayTitle = '집 비우는 날';

// ── 가전 선택 ─────────────────────────────────────────────────────────────

class _ApplianceSection extends ConsumerWidget {
  // 가전 목록은 홈·가전 탭과 같아 설정에서 뺐다(10/25 사용자 — 굳이 두 번). 여기엔 이 폰에서 바꾼 가전이
  // 본체에 아직 없을 때만 그 사실과 '본체에도 똑같이 맞추기'를 둔다. 평상시에는 묶음째 보이지 않는다.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hasPendingSyncProvider)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: '가전'),
        const SizedBox(height: AppSpace.sm),
        SyncStatusLine(onRetry: () => _resyncCustomAppliances(context, ref)),
        const SizedBox(height: AppSpace.md),
        TextButton.icon(
          onPressed: () => _resyncCustomAppliances(context, ref),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          ),
          icon: Icon(Icons.sync, size: 18, color: context.appMuted),
          // 낱말 중간에서 꺾이지 않게('다 / 시' 방지, 큰 글씨).
          label: Text(
            keepWordsTogether(kResyncLabel),
            semanticsLabel: kResyncLabel,
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
        ),
        const SizedBox(height: AppSpace.xxxl),
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
      return kSyncConflictMessage;
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
                a.canExecute ? '쓸 수 있어요' : '지금은 쓸 수 없어요',
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
                                      : '아직 준비되지 않았어요'),
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
