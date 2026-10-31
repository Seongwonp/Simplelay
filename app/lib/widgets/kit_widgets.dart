import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/hub.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 세트가 없을 때 — 찾을 때까지 다음으로 가지 않으므로 할 일을 함께 말한다.
const kKitNotFoundGuide = '누름 장치 세트를 찾지 못했어요. 세트 전원을 켜고 본체와 같은 와이파이에 있는지 확인한 뒤 다시 찾아 주세요.';

/// 세트가 [name]을 맡고 있을 때의 문구.
String kitInUseText(String name) => '이 세트는 $name에 연결돼 있어요';

/// 연결 해제 단추 글자.
String kitReleaseLabel(String name) => '$name 연결 해제 후 새 가전에 연결';

/// 세트를 다른 가전에서 뺄 때 묻는다. 예면 true.
Future<bool> confirmKitRelease(BuildContext context, String name) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('$name 연결을 풀까요?'),
      content: Text('$name의 버튼 자리는 그대로 남지만, 다시 연결할 때까지 쓸 수 없어요.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('취소')),
        FilledButton(
          key: const Key('kit-release-confirm'),
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('연결 풀기'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// 세트 상태 줄들 — 모션·콘센트·원점·비상 버튼.
class KitFacts extends StatelessWidget {
  const KitFacts({super.key, required this.kit});
  final KitStatus kit;

  @override
  Widget build(BuildContext context) {
    final mock = kit.motion == 'mock';
    Widget line(String text, {bool warn = false}) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xs),
          child: Text(text,
              style: TextStyle(
                  fontSize: AppFont.caption, color: warn ? context.appWarning : context.appMuted)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(mock
            ? '누름 장치: 연습용(실제로 움직이지 않아요)'
            : kit.motionPresent
                ? '누름 장치: 연결됨'
                : '누름 장치: 응답 없음',
            warn: !mock && !kit.motionPresent),
        line(kit.outletPresent ? '전기 플러그(전력 확인): 연결됨' : '전기 플러그(전력 확인): 없음', warn: !kit.outletPresent),
        if (!mock && kit.motionPresent && kit.homed == false) line('원점을 아직 잡지 않았어요', warn: true),
        if (kit.estopNote != null) line(kit.estopNote!, warn: true),
      ],
    );
  }
}

/// 가전 추가 첫 단계 — 세트를 찾았나, 다른 가전이 쓰고 있나.
class KitFindStep extends StatelessWidget {
  const KitFindStep({
    super.key,
    required this.kit,
    required this.loading,
    required this.failed,
    required this.releaseConfirmed,
    required this.onRetry,
    required this.onRelease,
  });

  final KitStatus? kit;
  final bool loading;

  /// 본체에 물어보지 못했다(연결 문제).
  final bool failed;
  final bool releaseConfirmed;
  final VoidCallback onRetry;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final k = kit;
    if (loading) return const LinearProgressIndicator(key: Key('wizard-kit-loading'));
    final found = k?.found ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!found) ...[
          Text(failed ? '본체에 물어보지 못했어요. 연결을 확인한 뒤 다시 찾아 주세요.' : (k?.reason ?? kKitNotFoundGuide),
              key: const Key('wizard-kit-missing'),
              style: TextStyle(fontSize: AppFont.body, color: context.appWarning)),
          const SizedBox(height: AppSpace.md),
          OutlinedButton.icon(
            key: const Key('wizard-kit-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 찾기'),
          ),
        ] else ...[
          Text('누름 장치 세트를 찾았어요',
              key: const Key('wizard-kit-found'),
              style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.sm),
          KitFacts(kit: k!),
          if (k.boundName != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(kitInUseText(k.boundName!),
                key: const Key('wizard-kit-in-use'),
                style: TextStyle(fontSize: AppFont.body, color: context.appWarning)),
            const SizedBox(height: AppSpace.sm),
            if (releaseConfirmed)
              Text('새 가전을 저장할 때 ${k.boundName} 연결을 풀어요.',
                  key: const Key('wizard-kit-release-noted'),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
            else
              FilledButton(
                key: const Key('wizard-kit-release'),
                onPressed: onRelease,
                child: Text(kitReleaseLabel(k.boundName!)),
              ),
          ],
        ],
      ],
    );
  }
}

/// 세트가 없는 가전의 상세 화면 — 세트를 다시 잇고 자리 확인으로 보낸다.
class KitReconnectButton extends ConsumerStatefulWidget {
  const KitReconnectButton({super.key, required this.appliance});
  final ApplianceMap appliance;

  @override
  ConsumerState<KitReconnectButton> createState() => _KitReconnectButtonState();
}

class _KitReconnectButtonState extends ConsumerState<KitReconnectButton> {
  bool _busy = false;
  String? _error;

  Future<void> _reconnect() async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      setState(() => _error = '본체와 연결되면 다시 해 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final kit = await api.kitStatus();
      if (!mounted) return;
      if (!kit.found) {
        setState(() => _error = kit.reason ?? kKitNotFoundGuide);
        return;
      }
      final holder = kit.boundAppliance == widget.appliance.id ? null : kit.boundName;
      if (holder != null && !await confirmKitRelease(context, holder)) return;
      await api.bindKit(widget.appliance.id, confirmRelease: holder != null);
      if (!mounted) return;
      unawaited(ref.read(serverApplianceCatalogProvider.notifier).refresh());
      // 세트를 옮겼으니 저장된 자리가 맞는지 다시 본다 — 여기까지 끝나야 쓸 수 있다.
      context.push('/appliance/setup?verify=1', extra: widget.appliance);
    } on RpiApiException catch (e) {
      if (mounted) setState(() => _error = e.statusCode == 0 ? '본체와 연결되면 다시 해 주세요.' : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '본체와 연결되면 다시 해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            key: const Key('kit-reconnect'),
            onPressed: _busy ? null : _reconnect,
            icon: const Icon(Icons.link),
            label: const Text('세트 다시 연결'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(_error!,
                  key: const Key('kit-reconnect-error'),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
            ),
        ],
      );
}
