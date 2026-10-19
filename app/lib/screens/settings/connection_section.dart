part of '../settings_screen.dart';

// ── RPi 연결 상태 타일 ────────────────────────────────────────────────────

class _RpiConnectionTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connState = ref.watch(rpiConnectionProvider);
    // 사용자 문장이 먼저다. 주소·포트 같은 기술 상세는 고급 설정에서만
    // 보인다 -- 여기서 url을 되풀이하지 않는다.
    final (Color color, String label, IconData icon) = switch (connState) {
      RpiConnectionState.unconfigured => (
          context.appMuted,
          '아직 주소가 없어요. 아래 설치하는 분용에서 넣어요',
          Icons.wifi_off
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          '알아보고 있어요…',
          Icons.sync
        ),
      RpiConnectionState.keyRequired => (context.appWarning, '연결 비밀번호가 필요해요', Icons.key),
      RpiConnectionState.connected => (
          context.appSuccess,
          '연결됨',
          Icons.wifi
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
          '연결이 끊겼어요',
          Icons.wifi_off
        ),
    };

    final retry = OutlinedButton(
      onPressed: connState == RpiConnectionState.checking
          ? null
          : () => ref.read(rpiConnectionProvider.notifier).check(),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        minimumSize: const Size(48, 48),
      ),
      child: connState == RpiConnectionState.checking
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('다시 찾기', style: TextStyle(fontSize: AppFont.caption)),
    );
    // 큰 글씨에서는 오른쪽 버튼이 제목을 세 줄로 꺾는다. 버튼을 아래로.
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.5;

    return _SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: color, size: 22),
            // 200%에서 폭에 들어가는 길이로. 무엇인지는 아래 문장이 말한다.
            title: const Text('본체'),
            subtitle: Text(
              label,
              style: TextStyle(color: color, fontSize: AppFont.caption),
            ),
            trailing: stacked ? null : retry,
          ),
          if (stacked)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: retry,
            ),
        ],
      ),
    );
  }
}

// ── 저장된 BLE 기기 ───────────────────────────────────────────────────────

class _SavedDeviceSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDeviceProvider);
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final isConnected = connection == BleConnectionState.connected;

    if (saved == null) {
      return _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.bluetooth_disabled, color: context.appMuted, size: 22),
          // 서버가 안 될 때 쓰는 두 번째 길. 이름부터 그렇게 부른다.
          title: const Text('블루투스 연결'),
          subtitle: Text('저장된 기기가 없어요. 아래 설치하는 분용에서 찾아요',
              style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
        ),
      );
    }

    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: isConnected ? context.appInk : context.appMuted,
          size: 22,
        ),
        title: Text('블루투스 연결: ${saved.name}'),
        subtitle: Text(
          isConnected ? '연결됨' : '끊김',
          style: TextStyle(
            color: isConnected ? context.appSuccess : context.appMuted,
            fontSize: AppFont.caption,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isConnected)
              OutlinedButton(
                onPressed: () async {
                  // 저장된 기기를 실제로 스캔해서 찾는다 — 이전 구현은 스캔을
                  // 시작하지도 않고 결과 스트림의 첫 이벤트를 기다려서, 다른
                  // 스캔이 돌고 있지 않으면 영원히 완료되지 않았다.
                  final ble = ref.read(bleServiceProvider);
                  final messenger = ScaffoldMessenger.of(context);
                  ScanResult? match;
                  try {
                    await for (final results in ble
                        .scan(timeout: const Duration(seconds: 8))
                        .timeout(const Duration(seconds: 9))) {
                      match = results
                          .where(
                              (r) => r.device.remoteId.toString() == saved.id)
                          .firstOrNull;
                      if (match != null) break;
                    }
                  } catch (_) {
                    // 타임아웃 포함 — match == null로 아래에서 안내
                  }
                  await ble.stopScan();
                  if (match == null) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('저장된 기기를 찾지 못했어요. 기기 전원을 봐 주세요.'),
                    ));
                    return;
                  }
                  try {
                    await ble.connect(match.device);
                  } catch (_) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('연결하지 못했어요. 다시 해 주세요.'),
                    ));
                  }
                },
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('다시 연결', style: TextStyle(fontSize: AppFont.caption)),
              ),
            IconButton(
              onPressed: () => ref.read(savedDeviceProvider.notifier).clear(),
              icon: const Icon(Icons.delete_outline, size: 16),
              color: context.appMuted,
              tooltip: '지우기',
              padding: const EdgeInsets.all(AppSpace.xs),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 고급 설정 (URL 오버라이드) ────────────────────────────────────────────

class _AdvancedSection extends ConsumerWidget {
  const _AdvancedSection({
    required this.controller,
    required this.apiKeyController,
    required this.urlEdited,
    required this.apiKeyEdited,
  });
  final TextEditingController controller;
  final TextEditingController apiKeyController;

  /// 사용자가 칸을 실제로 고쳤는지. 고치지 않은 칸은 저장하지 않는다 --
  /// 설정을 읽기 전에 빈 칸으로 열린 화면이 저장된 값을 지우지 않게.
  final bool Function() urlEdited;
  final bool Function() apiKeyEdited;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '본체 주소 (설치하는 분용)',
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '기본값: http://simplelay.local:8000\n'
            '같은 와이파이에서 본체를 찾아요.',
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'http://simplelay.local:8000',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: AppFont.caption),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: (_) => _save(ref),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              FilledButton(
                onPressed: () => _save(ref),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('저장', style: TextStyle(fontSize: AppFont.caption)),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '연결 비밀번호 (설치하는 분용)',
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '본체를 설치할 때 정한 비밀번호를 넣어 주세요.',
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
          ),
          const SizedBox(height: AppSpace.sm),
          _HubKeyField(controller: apiKeyController, onSubmitted: () => _save(ref)),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: () async {
              await ref.read(rpiUrlProvider.notifier).resetToDefault();
              controller.text = 'http://simplelay.local:8000';
              await ref.read(rpiConnectionProvider.notifier).check();
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
            ),
            child: Text('처음 값으로 되돌리기',
                style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
          ),
        ],
      );

  Future<void> _save(WidgetRef ref) async {
    await ref.read(rpiApiKeyProvider.notifier).ensureLoaded();
    await ref.read(rpiUrlProvider.notifier).ensureLoaded();
    if (apiKeyEdited()) {
      await ref.read(rpiApiKeyProvider.notifier).save(apiKeyController.text);
    }
    if (urlEdited()) {
      await ref.read(rpiUrlProvider.notifier).save(controller.text);
    }
    await ref.read(rpiConnectionProvider.notifier).check();
  }
}

// ── BLE 스캔 섹션 ─────────────────────────────────────────────────────────

class _BleSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(scanResultsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('주변 블루투스 기기',
                style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
            const Spacer(),
            IconButton(
              onPressed: () => ref.invalidate(scanResultsProvider),
              icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
              tooltip: '다시 찾기',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        results.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('찾지 못했어요. 블루투스가 켜져 있는지 봐 주세요.',
              style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
          data: (items) {
            final unique = <DeviceIdentifier, ScanResult>{
              for (final item in items) item.device.remoteId: item,
            }.values;
            if (unique.isEmpty) {
              return Text('찾은 기기가 없어요.',
                  style: TextStyle(color: context.appMuted, fontSize: AppFont.caption));
            }
            return Column(
              children: unique.map((result) {
                final name = result.device.platformName.isEmpty
                    ? '이름 없는 기기'
                    : result.device.platformName;
                return _SettingCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bluetooth, size: 20),
                    title: Text(name, style: const TextStyle(fontSize: AppFont.caption)),
                    subtitle: Text(
                      '${result.rssi} dBm',
                      style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
                    ),
                    trailing: FilledButton(
                      onPressed: () async {
                        try {
                          await ref
                              .read(bleServiceProvider)
                              .connect(result.device);
                          await ref.read(savedDeviceProvider.notifier).save(
                                result.device.remoteId.toString(),
                                name,
                              );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$name 연결했어요')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('연결하지 못했어요. 다시 해 주세요.')),
                            );
                          }
                        }
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.lg, vertical: AppSpace.sm),
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('연결', style: TextStyle(fontSize: AppFont.caption)),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

class _HubKeyField extends StatefulWidget {
  const _HubKeyField({required this.controller, required this.onSubmitted});
  final TextEditingController controller;
  final VoidCallback onSubmitted;
  @override
  State<_HubKeyField> createState() => _HubKeyFieldState();
}

class _HubKeyFieldState extends State<_HubKeyField> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    obscureText: !_visible,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(
      border: const OutlineInputBorder(),
      hintText: '연결 비밀번호를 넣어 주세요',
      suffixIcon: IconButton(
        tooltip: _visible ? '비밀번호 숨기기' : '비밀번호 보기',
        icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
        onPressed: () => setState(() => _visible = !_visible),
      ),
    ),
    onSubmitted: (_) => widget.onSubmitted(),
  );
}
