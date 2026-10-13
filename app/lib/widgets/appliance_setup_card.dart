import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/appliance.dart';
import '../models/hub.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_text.dart';

/// 가전 하나의 확인 주행 조회. 실패를 '기록 없음'으로 뭉개지 않는다(2026-10-13).
///
/// - 200 → [VerifyPassLookup.found]
/// - 404 + 서버의 기록 없음 문장 → [VerifyPassLookup.noRecord]
/// - 그 밖(일반 404·다른 상태·응답 해석 실패·예외·허브 없음) → [VerifyPassLookup.unknown]
Future<VerifyPassLookup> lookupVerifyPass(RpiApiService? api, String id) async {
  if (api == null) return const VerifyPassLookup.unknown();
  try {
    return VerifyPassLookup.found(await api.verifyPassStatus(id));
  } on RpiApiException catch (e) {
    if (e.statusCode == 404 && e.message == VerifyPassLookup.noRecordDetail) {
      return const VerifyPassLookup.noRecord();
    }
    return const VerifyPassLookup.unknown();
  } catch (_) {
    return const VerifyPassLookup.unknown();
  }
}

/// 로딩 중에는 값이 없다 — 읽는 쪽은 `valueOrNull ?? VerifyPassLookup.unknown()`.
final setupPassProvider = FutureProvider.autoDispose
    .family<VerifyPassLookup, String>((ref, id) =>
        lookupVerifyPass(ref.watch(rpiApiServiceProvider), id));

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
    final pass = ref.watch(setupPassProvider(appliance.id)).valueOrNull?.pass;
    final mapped = appliance.panelMapping != null;
    final verified = pass?.state == 'done' && pass?.executionMode == 'real';
    final remaining = (mapped ? 0 : 1) + (verified ? 0 : 1);
    if (remaining == 0) return const SizedBox.shrink();
    void open(String location) {
      final router = GoRouter.of(context);
      if (closeSheetFirst) Navigator.of(context).pop();
      router.push(location, extra: appliance);
    }
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${appliance.name} · 설정이 $remaining개 남았어요'),
        if (pass?.isMock == true) const Text('모의 주행을 확인했어요. 실제 위치는 확인이 필요해요.'),
        Wrap(spacing: 12, children: [
          OutlinedButton(onPressed: () => open('/appliance/setup'),
            child: const Text('위치 맞추기')),
          if (mapped) FilledButton(onPressed: () => open('/appliance/setup?verify=1'),
            child: const Text('확인 주행')),
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
            !_setupDone(a, ref.watch(setupPassProvider(a.id)).valueOrNull?.pass))
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
    // 홈 가전 목록 **아래**의 작은 안내(2026-10-13). 카드로 감싸 맨 위를 차지하지
    // 않는다 — 각 타일이 '설정이 필요해요'로 말하고, 이어 하는 길만 남긴다.
    return Padding(
      key: const Key('setup-summary-card'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('설정이 남은 가전 ${appliances.length}개'),
        Text(
          setupSummaryNames(appliances),
          style: context.appCaption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        TextButton(
          onPressed: () => _openList(context),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          child: const Text('설정 이어하기'),
        ),
      ]),
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('설정이 남은 가전', style: AppText.title),
            const SizedBox(height: 8),
            for (final a in appliances)
              ApplianceSetupCard(appliance: a, closeSheetFirst: true),
          ],
        ),
      ),
    );
  }
}
