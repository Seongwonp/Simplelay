import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/appliance.dart';
import '../models/display_status.dart' show verifyPassLookupNote;
import '../models/hub.dart';
import '../models/line_break.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// 가전 하나의 확인 주행 조회. 실패를 '기록 없음'으로 뭉개지 않는다(2026-10-13).
///
/// - 200 + state(running·done·failed) → [VerifyPassLookup.found]
/// - 200인데 state가 없거나 모르는 값 → [VerifyPassLookup.unknown]
/// - 404 + 서버의 기록 없음 문장 → [VerifyPassLookup.noRecord]
/// - 그 밖(일반 404·다른 상태·응답 해석 실패·예외·허브 없음) → [VerifyPassLookup.unknown]
Future<VerifyPassLookup> lookupVerifyPass(RpiApiService? api, String id) async {
  if (api == null) return const VerifyPassLookup.unknown();
  try {
    final pass = await api.verifyPassStatus(id);
    // 해석은 됐지만 state가 없거나 모르는 값 — 서버가 실패를 말한 것이 아니다(검토 M2).
    if (!pass.stateKnown) return const VerifyPassLookup.unknown();
    return VerifyPassLookup.found(pass);
  } on RpiApiException catch (e) {
    if (e.statusCode == 404 && e.message == VerifyPassLookup.noRecordDetail) {
      return const VerifyPassLookup.noRecord();
    }
    return const VerifyPassLookup.unknown();
  } catch (_) {
    return const VerifyPassLookup.unknown();
  }
}

/// 가전 하나의 확인 주행 조회. 읽는 쪽은 [setupPassLookupOf]로 읽는다.
///
/// 허브가 **다시 연결되면** 새로 묻는다(검토 M3, 2026-10-13) — 서버가 재시작해 메모리의
/// 확인 주행 기록이 사라졌거나, 끊기기 전 조회가 실패했을 수 있다. 홈이 계속 구독해
/// autoDispose되지 않으므로 연결을 듣지 않으면 예전 결과가 남는다. 연결이 아닐 때는
/// 묻지 않고 모름이다.
final setupPassProvider = FutureProvider.autoDispose
    .family<VerifyPassLookup, String>((ref, id) {
  final connected = ref.watch(rpiConnectionProvider
      .select((s) => s == RpiConnectionState.connected));
  final api = ref.watch(rpiApiServiceProvider);
  if (!connected) return const VerifyPassLookup.unknown();
  return lookupVerifyPass(api, id);
});

/// 조회 중(다시 묻는 중 포함)·오류·값 없음은 모름 — 예전 결과를 지금의 것으로 쓰지 않는다.
VerifyPassLookup setupPassLookupOf(AsyncValue<VerifyPassLookup> value) =>
    value.isLoading || !value.hasValue
        ? const VerifyPassLookup.unknown()
        : value.requireValue;

/// 위치를 맞췄고 실제 확인 주행까지 끝났는가.
bool _setupDone(ApplianceMap appliance, VerifyPass? pass) =>
    appliance.panelMapping != null &&
    pass?.state == 'done' &&
    pass?.executionMode == 'real';

class ApplianceSetupCard extends ConsumerWidget {
  const ApplianceSetupCard({
    super.key,
    required this.appliance,
    this.closeSheetFirst = false,
    this.flat = false,
  });
  final ApplianceMap appliance;

  /// 다른 카드('확인이 필요해요') 안에 놓일 때 — 카드를 겹치지 않는다(2026-10-18).
  final bool flat;

  /// 아래 목록(시트) 안에서 쓰일 때 -- 다음 화면을 열기 전에 시트를 닫는다.
  final bool closeSheetFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = setupPassLookupOf(ref.watch(setupPassProvider(appliance.id)));
    final pass = lookup.pass;
    final mapped = appliance.panelMapping != null;
    final verified = pass?.state == 'done' && pass?.executionMode == 'real';
    // 모의 확인 주행을 **마친** 경우만 '모의 주행을 확인했어요'. 모의 실패·진행 중·
    // 기록 없음·모름은 타일 보조 줄과 같은 말로(검토 M4, 2026-10-13).
    final mockDone = pass?.state == 'done' && pass?.isMock == true;
    final passNote = !mapped || mockDone ? null : verifyPassLookupNote(lookup);
    final remaining = (mapped ? 0 : 1) + (verified ? 0 : 1);
    if (remaining == 0) return const SizedBox.shrink();
    void open(String location) {
      final router = GoRouter.of(context);
      if (closeSheetFirst) Navigator.of(context).pop();
      router.push(location, extra: appliance);
    }
    final body = Padding(
      padding: flat
          ? const EdgeInsets.only(top: AppSpace.sm, right: AppSpace.sm)
          : const EdgeInsets.all(AppSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 낱말 중간에서 꺾이지 않게(평가 4차 10/18: '세탁 / 기').
        Text(keepWordsTogether('${appliance.name}, 설정이 $remaining개 남았어요')),
        if (mockDone) Text(keepWordsTogether('연습으로만 시험 이동했어요. 실제 자리는 아직 몰라요.')),
        if (passNote != null) Text(keepWordsTogether(passNote)),
        Wrap(spacing: AppSpace.md, children: [
          OutlinedButton(onPressed: () => open('/appliance/setup'),
            child: const Text('위치 맞추기')),
          // 테두리 버튼 — 홈의 채운 주 버튼은 '지금 하기' 하나다(2026-10-18 버튼 위계).
          if (mapped) OutlinedButton(onPressed: () => open('/appliance/setup?verify=1'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('시험 이동')),
        ]),
      ]),
    );
    return flat ? body : Card(child: body);
  }
}

/// 설정이 남은 가전(위치 미설정, 또는 실제 확인 주행 전). 홈 '확인이 필요해요'가 쓴다(2026-10-18).
///
/// 위치를 아직 안 맞춘 가전은 그것만으로 설정이 남았으니 확인 주행 상태를
/// 묻지 않는다. 묻는 것은 위치를 맞춘 가전뿐이다(가전마다 요청하지 않게).
List<ApplianceMap> pendingSetupAppliances(WidgetRef ref, List<ApplianceMap> appliances) => [
      for (final a in appliances)
        if (a.panelMapping == null ||
            !_setupDone(a, setupPassLookupOf(ref.watch(setupPassProvider(a.id))).pass))
          a,
    ];

/// 이름을 짧게 잇는다 -- 세 대까지 적고 나머지는 '외 N개'.
String setupSummaryNames(List<ApplianceMap> appliances) {
  const shown = 3;
  final names = appliances.take(shown).map((a) => a.name).join(', ');
  final rest = appliances.length - shown;
  return rest > 0 ? '$names 외 $rest대' : names;
}

/// '확인이 필요해요' 안의 한 줄 — '세탁기, 인터폰 설정이 남았어요', 누르면 가전별 설정 카드 목록(시트).
///
/// 설정이 남았다는 말은 홈에서 **이 한 줄만** 한다(평가 3차 10/18) — 가전 타일은 아이콘 점, 루틴 타일은
/// 말하지 않는다. 그래서 어느 가전인지 이름을 여기서 적는다(세 대 넘으면 '외 N대').
class SetupSummaryRow extends StatelessWidget {
  const SetupSummaryRow({super.key, required this.appliances});
  final List<ApplianceMap> appliances;

  @override
  Widget build(BuildContext context) {
    final text = appliances.length == 1
        ? '${appliances.single.name}, 설정이 남았어요'
        : '${setupSummaryNames(appliances)} 설정이 남았어요';
    return Semantics(
      key: const Key('setup-summary-card'),
      container: true,
      button: true,
      label: '가전 ${appliances.length}대 설정이 남았어요, ${setupSummaryNames(appliances)}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _openList(context),
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(children: [
            Icon(Icons.tune, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            // 낱말 중간에서 꺾이지 않게(평가 4차 10/18: 큰 글씨 '전자레인지, 세탁 / 기 설정이…').
            Expanded(child: Text(keepWordsTogether(text), style: const TextStyle(fontSize: AppFont.caption))),
            Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  void _openList(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.xxl),
          children: [
            Text('설정이 남은 가전', style: AppText.title),
            const SizedBox(height: AppSpace.sm),
            for (final a in appliances)
              ApplianceSetupCard(appliance: a, closeSheetFirst: true),
          ],
        ),
      ),
    );
  }
}
