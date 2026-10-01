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
          '아직 주소가 없어요 — 고급 설정에서 입력',
          Icons.wifi_off
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          '확인하는 중이에요…',
          Icons.sync
        ),
      RpiConnectionState.connected => (
          context.appSuccess,
          '연결됐어요 — 버튼을 대신 눌러 줄 수 있어요',
          Icons.wifi
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
          '지금은 닿지 않아요',
          Icons.wifi_off
        ),
    };

    final retry = OutlinedButton(
      onPressed: connState == RpiConnectionState.checking
          ? null
          : () => ref.read(rpiConnectionProvider.notifier).check(),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: const Size(48, 48),
      ),
      child: connState == RpiConnectionState.checking
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('다시 확인', style: TextStyle(fontSize: 14)),
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
            title: const Text('허브'),
            subtitle: Text(
              label,
              style: TextStyle(color: color, fontSize: 14),
            ),
            trailing: stacked ? null : retry,
          ),
          if (stacked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
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
          title: const Text('예비 연결 (블루투스)'),
          subtitle: Text('저장된 기기가 없어요 — 고급 설정에서 찾기',
              style: TextStyle(color: context.appMuted, fontSize: 14)),
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
        title: Text('예비 연결 · ${saved.name}'),
        subtitle: Text(
          isConnected ? '연결됐어요' : '지금은 끊겨 있어요',
          style: TextStyle(
            color: isConnected ? context.appSuccess : context.appMuted,
            fontSize: 14,
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
                      content: Text('저장된 기기를 찾지 못했어요. 기기 전원을 확인해주세요.'),
                    ));
                    return;
                  }
                  try {
                    await ble.connect(match.device);
                  } catch (_) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text('연결에 실패했어요. 다시 시도해주세요.'),
                    ));
                  }
                },
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('재연결', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              onPressed: () => ref.read(savedDeviceProvider.notifier).clear(),
              icon: const Icon(Icons.delete_outline, size: 16),
              color: context.appMuted,
              tooltip: '삭제',
              padding: const EdgeInsets.all(4),
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
            '허브 주소',
            style: TextStyle(color: context.appMuted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '기본값: http://simplelay.local:8000\n'
            '같은 Wi-Fi에서 mDNS로 자동 연결돼요.',
            style: TextStyle(color: context.appMuted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'http://simplelay.local:8000',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onSubmitted: (_) => _save(ref),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _save(ref),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('저장', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'API 키 (선택)',
            style: TextStyle(color: context.appMuted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '서버에 SIMPLELAY_API_KEY가 설정된 경우에만 입력하세요.\n'
            '시연장 같은 공유 Wi-Fi에서 외부 접근을 막을 때 써요.',
            style: TextStyle(color: context.appMuted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: apiKeyController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '미설정 시 비워두세요',
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
            autocorrect: false,
            obscureText: true,
            onSubmitted: (_) => _save(ref),
          ),
          const SizedBox(height: 6),
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
            child: Text('기본값으로 초기화',
                style: TextStyle(color: context.appMuted, fontSize: 12)),
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
            Text('주변 BLE 기기',
                style: TextStyle(color: context.appMuted, fontSize: 13)),
            const Spacer(),
            IconButton(
              onPressed: () => ref.invalidate(scanResultsProvider),
              icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
              tooltip: '다시 스캔',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
        const SizedBox(height: 8),
        results.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('스캔 실패: $e',
              style: TextStyle(color: context.appMuted, fontSize: 12)),
          data: (items) {
            final unique = <DeviceIdentifier, ScanResult>{
              for (final item in items) item.device.remoteId: item,
            }.values;
            if (unique.isEmpty) {
              return Text('찾은 기기가 없어요.',
                  style: TextStyle(color: context.appMuted, fontSize: 12));
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
                    title: Text(name, style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      '${result.rssi} dBm',
                      style: TextStyle(color: context.appMuted, fontSize: 11),
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
                              SnackBar(content: Text('$name 연결 완료')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('연결 실패: $e')),
                            );
                          }
                        }
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('연결', style: TextStyle(fontSize: 12)),
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
