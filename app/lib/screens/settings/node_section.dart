part of '../settings_screen.dart';

// ── ESP32 노드 등록 ───────────────────────────────────────────────────────

class _NodeSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(installedAppliancesProvider);
    final nodesAsync = ref.watch(nodeRegistryProvider);
    // 등록할 가전이 없으면 노드 목록을 부를 이유도 없다.
    if (appliances.isEmpty) {
      return _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.add_home_outlined, color: context.appMuted, size: 20),
          title: const Text('등록할 가전이 아직 없어요'),
          subtitle: Text(
            '가전을 추가하면 여기서 버튼을 눌러 줄 장치를 연결해요.',
            style: TextStyle(color: context.appMuted, fontSize: 14),
          ),
        ),
      );
    }

    return nodesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, __) => _SettingCard(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.error_outline, color: context.appMuted, size: 20),
          title: Text('가전 연결 상태를 불러오지 못했어요',
              style: TextStyle(color: context.appMuted, fontSize: 14)),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: context.appMuted, size: 18),
            onPressed: () => ref.invalidate(nodeRegistryProvider),
          ),
        ),
      ),
      data: (nodes) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '가전마다 버튼을 눌러 줄 장치',
              style: TextStyle(fontSize: 15, color: context.appMuted),
            ),
          ),
          ...appliances.map((appliance) {
            final url = nodes[appliance.id];
            return _SettingCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(appliance.icon,
                    color: url != null ? context.appSuccess : context.appMuted,
                    size: 20),
                title: Text(appliance.displayName),
                // 주소는 편집 시트에서만. 목록에서는 이어졌는지만 말한다.
                subtitle: Text(
                  url != null ? '장치가 이어져 있어요' : '아직 장치가 없어요',
                  style: TextStyle(
                    color: url != null ? context.appSuccess : context.appMuted,
                    fontSize: 14,
                  ),
                ),
                trailing: IconButton(
                  icon: Icon(
                    url != null
                        ? Icons.edit_outlined
                        : Icons.add_circle_outline,
                    color: context.appMuted,
                    size: 18,
                  ),
                  onPressed: () => _showNodeSheet(context, ref, appliance, url),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  void _showNodeSheet(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap appliance,
    String? currentUrl,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NodeEditSheet(
        appliance: appliance,
        currentUrl: currentUrl,
        onSave: (url) async {
          final service = ref.read(rpiApiServiceProvider);
          if (service == null) return false;
          final ok = await service.registerNode(appliance.id, url);
          if (ok) ref.invalidate(nodeRegistryProvider);
          return ok;
        },
        onUnregister: () async {
          final service = ref.read(rpiApiServiceProvider);
          if (service == null) return false;
          final ok = await service.unregisterNode(appliance.id);
          if (ok) ref.invalidate(nodeRegistryProvider);
          return ok;
        },
      ),
    );
  }
}

class _NodeEditSheet extends StatefulWidget {
  const _NodeEditSheet({
    required this.appliance,
    required this.currentUrl,
    required this.onSave,
    required this.onUnregister,
  });

  final ApplianceMap appliance;
  final String? currentUrl;
  final Future<bool> Function(String url) onSave;
  final Future<bool> Function() onUnregister;

  @override
  State<_NodeEditSheet> createState() => _NodeEditSheetState();
}

class _NodeEditSheetState extends State<_NodeEditSheet> {
  late final TextEditingController _ctrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentUrl ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _normalize(String input) {
    final s = input.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.contains(':')) return 'http://$s';
    return 'http://$s:8080';
  }

  Future<void> _save() async {
    final url = _normalize(_ctrl.text);
    if (url.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onSave(url);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = '저장하지 못했어요. 허브 연결을 확인하고 다시 저장해 주세요.';
      });
    }
  }

  Future<void> _unregister() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onUnregister();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = '해제 실패';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegistered = widget.currentUrl != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              // 핸들
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.appOutline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // 헤더
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(widget.appliance.icon,
                        color: context.appMuted, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      '${widget.appliance.name} 노드 등록',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isRegistered) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.appSuccess.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: context.appSuccess.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          '등록됨',
                          style: TextStyle(
                              fontSize: 14, color: context.appSuccess),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '플러그 주소를 입력해 주세요',
                  style: TextStyle(fontSize: 14, color: context.appMuted),
                ),
              ),

              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 16),

              // 입력 필드
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: '192.168.x.x  또는  http://...:8080',
                    hintStyle: TextStyle(fontSize: 13, color: context.appMuted),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 14),
                  onSubmitted: (_) => _save(),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 14, color: context.appDanger),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // 버튼 행
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    if (isRegistered)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : _unregister,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.appDanger,
                            side: BorderSide(
                                color:
                                    context.appDanger.withValues(alpha: 0.5)),
                          ),
                          child: const Text('해제'),
                        ),
                      ),
                    if (isRegistered) const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('저장'),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
