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
        // 평가 15차(10/18): 다른 설정 묶음과 같은 문법 — 줄 사이 옅은 구분선.
        for (final (i, appliance) in appliances.indexed) ...[
          if (i > 0) Divider(height: 1, color: context.appBorderFaint),
          ListTile(
            leading: Icon(appliance.icon),
            // 연습 가전은 '연습 세탁기'(접근성 감사 10/18 — 홈 타일·본체와 같은 표기, 서버 이름은 그대로).
            title: Text(applianceDisplayLine(appliance)),
            // 버튼 자리를 맞추지 않은 가전은 할 일만 짧게 한 줄(평가 7차 10/18: 주황 두 줄 + ⋮라 눌러도 되는지 헷갈렸다).
            subtitle: appliance.isCustom && !appliance.isThinq
                ? (needsPanelMapping(appliance)
                    // 어절 단위 줄바꿈('버 / 튼' 방지, 실화면 10/17).
                    ? _WordsText('버튼 자리를 맞춰 주세요',
                        style: TextStyle(fontSize: AppFont.caption, color: context.appWarning))
                    : null)
                // 평가 4차 10/18: '처음부터 들어 있는 가전이에요'·'빼기는 LG 가전 연결에서 해요'는 앱이 어떻게 만들어졌는지를
                // 말했다. 사용자가 할 일이 있을 때만 적는다 — LG 가전은 어디서 무엇을 하는지, 그 밖은 비운다.
                // 평가 11차(10/18): 'LG 앱에서 관리해요'는 여기서 못 다룬다는 오해 — 켜기·끄기는 줄을 눌러 들어간 상태 카드에서 한다.
                : appliance.isThinq && isPracticeAppliance(appliance)
                    // 연습 LG 가전(서버가 세운 모의 기기)은 LG 앱에서 등록할 것이 없다(보호자 과업 평가 10/18 —
                    // '등록은 LG 앱에서 해요'가 상세·홈과 어긋났다).
                    ? Text(kPracticeSubtitle,
                        key: const Key('settings-practice-subtitle'),
                        style: TextStyle(fontSize: AppFont.caption, color: context.appPractice))
                : appliance.isThinq
                    // 평가 12차(10/18): 한 줄로 이어 쓰니 'LG / 앱에서'로 끊겼다 → 두 문장을 두 줄로, 'LG 앱에서'는
                    // 붙여 둔다(줄바꿈 없는 빈칸). 낭독은 원문.
                    ? Text(
                        kThinqSubtitleLines.map(keepPhrasesTogether).join('\n'),
                        key: const Key('settings-thinq-subtitle'),
                        semanticsLabel: kThinqSubtitleLines.join(' '),
                        style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
                    : null,
            onTap: () => context.push('/appliance/detail/${appliance.id}'),
            // 줄 끝 표시는 하나, 모든 줄이 같은 >(평가 5차·7차 10/18) — 줄 전체가 눌려 상세로 간다는 뜻.
            // 지우기는 줄에 두지 않고 가전 상세 화면 위 ⋮ 한 곳(확인 대화는 그대로).
            trailing: Icon(Icons.chevron_right, color: context.appMuted),
          ),
        ],
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
            // 낱말 중간에서 꺾이지 않게('다 / 시' 방지, 큰 글씨).
            label: Text(
              keepWordsTogether(kResyncLabel),
              semanticsLabel: kResyncLabel,
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
