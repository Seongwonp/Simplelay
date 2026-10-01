import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/appliance.dart';
import '../models/hub.dart';
import '../providers/rpi_api_provider.dart';

final setupPassProvider = FutureProvider.autoDispose.family<VerifyPass?, String>((ref, id) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return null;
  try { return await api.verifyPassStatus(id); } catch (_) { return null; }
});

class ApplianceSetupCard extends ConsumerWidget {
  const ApplianceSetupCard({super.key, required this.appliance});
  final ApplianceMap appliance;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pass = ref.watch(setupPassProvider(appliance.id)).valueOrNull;
    final mapped = appliance.panelMapping != null;
    final verified = pass?.state == 'done' && pass?.executionMode == 'real';
    final remaining = (mapped ? 0 : 1) + (verified ? 0 : 1);
    if (remaining == 0) return const SizedBox.shrink();
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${appliance.name} · 설정이 $remaining개 남았어요'),
        if (pass?.isMock == true) const Text('모의 주행을 확인했어요. 실제 위치는 확인이 필요해요.'),
        Wrap(spacing: 12, children: [
          OutlinedButton(onPressed: () => context.push('/appliance/setup', extra: appliance),
            child: const Text('위치 맞추기')),
          if (mapped) FilledButton(onPressed: () => context.push('/appliance/setup?verify=1', extra: appliance),
            child: const Text('확인 주행')),
        ]),
      ]),
    ));
  }
}
