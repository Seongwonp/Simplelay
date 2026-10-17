import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/appliance.dart';
import '../models/display_status.dart' show verifyPassLookupNote;
import '../models/hub.dart';
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
  });
  final ApplianceMap appliance;

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
    return Card(child: Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${appliance.name}, 설정이 $remaining개 남았어요'),
        if (mockDone) const Text('연습으로만 시험 이동했어요. 실제 자리는 아직 몰라요.'),
        if (passNote != null) Text(passNote),
        Wrap(spacing: AppSpace.md, children: [
          OutlinedButton(onPressed: () => open('/appliance/setup'),
            child: const Text('위치 맞추기')),
          if (mapped) FilledButton(onPressed: () => open('/appliance/setup?verify=1'),
            child: const Text('시험 이동')),
        ]),
      ]),
    ));
  }
}

/// 홈의 '설정이 남은 가전' 자리 (2026-10-07).
///
/// 한 대면 그 가전 카드를 그대로 보인다. 둘 이상이면 **요약 카드 한 장**으로
/// 묶는다 -- 가전마다 카드를 쌓았더니 5대에서 '가전' 묶음이 첫 화면 밖으로
/// 밀렸다. 가전별 '위치 맞추기'는 '설정 이어하기'로 여는 목록에 있다.
///
/// 위치를 아직 안 맞춘 가전은 그것만으로 설정이 남았으니 확인 주행 상태를
/// 묻지 않는다. 묻는 것은 위치를 맞춘 가전뿐이다(가전마다 요청하지 않게).
class ApplianceSetupSection extends ConsumerWidget {
  const ApplianceSetupSection({super.key, required this.appliances});

  /// 설정 대상 후보(사용자 등록 가전). 끝난 것은 여기서 걸러진다.
  final List<ApplianceMap> appliances;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = [
      for (final a in appliances)
        if (a.panelMapping == null ||
            !_setupDone(
                a, setupPassLookupOf(ref.watch(setupPassProvider(a.id))).pass))
          a,
    ];
    if (pending.isEmpty) return const SizedBox.shrink();
    if (pending.length == 1) return ApplianceSetupCard(appliance: pending.single);
    return _SetupSummaryCard(appliances: pending);
  }
}

/// 이름을 짧게 잇는다 -- 세 대까지 적고 나머지는 '외 N개'.
String setupSummaryNames(List<ApplianceMap> appliances) {
  const shown = 3;
  final names = appliances.take(shown).map((a) => a.name).join(', ');
  final rest = appliances.length - shown;
  return rest > 0 ? '$names 외 $rest개' : names;
}

class _SetupSummaryCard extends StatelessWidget {
  const _SetupSummaryCard({required this.appliances});
  final List<ApplianceMap> appliances;

  @override
  Widget build(BuildContext context) {
    // 홈 가전 목록 **아래**의 한 줄(2026-10-14 UX). 각 타일이 이미 '설정이 필요해요'로
    // 말하므로 이름 목록·안내 문장을 되풀이하지 않고, 이어 하는 길만 남긴다.
    return Padding(
      key: const Key('setup-summary-card'),
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          label: '설정할 가전 ${appliances.length}개, ${setupSummaryNames(appliances)}',
          excludeSemantics: true,
          child: TextButton.icon(
            onPressed: () => _openList(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            ),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right, size: 20),
            label: Text('설정할 가전 ${appliances.length}개'),
          ),
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
