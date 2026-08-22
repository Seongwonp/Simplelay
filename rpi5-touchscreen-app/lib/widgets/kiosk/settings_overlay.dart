import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';

// 설정 진입: 대기 화면 우하단 상태 dot 3번 연속 탭
class KioskSettingsOverlay extends StatefulWidget {
  const KioskSettingsOverlay({
    super.key,
    required this.currentAppliance,
    required this.api,
    required this.onApplianceChanged,
    required this.onDismiss,
    this.ttsEnabled = true,
    this.onTtsChanged,
  });

  final ApplianceMap currentAppliance;
  final KioskApiService api;
  final ValueChanged<ApplianceMap> onApplianceChanged;
  final VoidCallback onDismiss;

  /// 음성 안내(espeak-ng) 켜짐 여부 + 토글 콜백
  final bool ttsEnabled;
  final ValueChanged<bool>? onTtsChanged;

  @override
  State<KioskSettingsOverlay> createState() => _KioskSettingsOverlayState();
}

class _KioskSettingsOverlayState extends State<KioskSettingsOverlay> {
  late ApplianceMap _selected;
  Map<String, String> _nodes = {};
  bool _loading = true;
  bool _saving = false;
  String? _saveError;
  late TextEditingController _urlCtrl;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentAppliance;
    _urlCtrl = TextEditingController()
      ..addListener(() => setState(() {}));
    _fetchNodes();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchNodes() async {
    setState(() => _loading = true);
    final nodes = await widget.api.listNodes();
    if (!mounted) return;
    final nodeMap = {for (final n in nodes) n.applianceId: n.baseUrl};
    _urlCtrl.text = nodeMap[_selected.id] ?? '';
    setState(() {
      _nodes = nodeMap;
      _loading = false;
    });
  }

  void _selectAppliance(ApplianceMap a) {
    _urlCtrl.text = _nodes[a.id] ?? '';
    setState(() {
      _selected = a;
      _saveError = null;
    });
  }

  String _normalizeUrl(String input) {
    final s = input.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.contains(':')) return 'http://$s';
    return 'http://$s:8080';
  }

  Future<void> _save() async {
    final raw = _urlCtrl.text.trim();
    setState(() {
      _saving = true;
      _saveError = null;
    });

    bool ok;
    if (raw.isEmpty) {
      ok = await widget.api.unregisterNode(_selected.id);
      if (ok && mounted) setState(() => _nodes.remove(_selected.id));
    } else {
      final url = _normalizeUrl(raw);
      ok = await widget.api.registerNode(_selected.id, url);
      if (ok && mounted) {
        _urlCtrl.text = url; // listener에서 rebuild 예약됨
        setState(() => _nodes[_selected.id] = url);
      }
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveError = ok ? null : '저장 실패 — 서버에 연결되어 있는지 확인하세요';
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        FocusScope.of(context).unfocus();
        widget.onDismiss();
      },
      child: ColoredBox(
        color: const Color(0xCC0C0E12),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 480,
              constraints: const BoxConstraints(maxHeight: 440),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: KioskColors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  _buildTtsSection(),
                  const SizedBox(height: 16),
                  const Divider(color: KioskColors.border, height: 1),
                  const SizedBox(height: 16),
                  _buildApplianceSection(),
                  const SizedBox(height: 20),
                  const Divider(color: KioskColors.border, height: 1),
                  const SizedBox(height: 20),
                  _buildNodeSection(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() => Row(
        children: [
          const Text(
            '키오스크 설정',
            style: TextStyle(
              fontSize: 16,
              color: Color(0xFFFAF7F2),
              fontWeight: FontWeight.w300,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: widget.onDismiss,
            child: const Icon(Icons.close, color: KioskColors.muted, size: 20),
          ),
        ],
      );

  Widget _buildTtsSection() => Row(
        children: [
          const Icon(Icons.record_voice_over,
              color: KioskColors.muted, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '음성 안내',
                  style: TextStyle(fontSize: 14, color: Color(0xFFFAF7F2)),
                ),
                Text(
                  '제안·실행 결과·위험 경보를 소리로 읽어줍니다',
                  style: TextStyle(fontSize: 11, color: KioskColors.muted),
                ),
              ],
            ),
          ),
          Switch(
            value: widget.ttsEnabled,
            activeTrackColor: KioskColors.primary.withValues(alpha: 0.5),
            activeThumbColor: KioskColors.primary,
            onChanged: widget.onTtsChanged,
          ),
        ],
      );

  Widget _buildApplianceSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('제어 가전'),
          const SizedBox(height: 10),
          Row(
            children: [
              ...kAppliances.map((a) {
                final isActive = a.id == widget.currentAppliance.id;
                final isSelected = a.id == _selected.id;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _selectAppliance(a),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? KioskColors.primary.withValues(alpha: 0.15)
                            : KioskColors.surface2,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? KioskColors.primary.withValues(alpha: 0.6)
                              : KioskColors.border,
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            a.icon,
                            size: 15,
                            color: isSelected
                                ? KioskColors.primary
                                : KioskColors.muted,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            a.name,
                            style: TextStyle(
                              fontSize: 13,
                              color: isSelected
                                  ? KioskColors.primary
                                  : const Color(0xFFFAF7F2),
                              fontWeight: isSelected
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 7),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: KioskColors.success,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const Spacer(),
              if (_selected.id != widget.currentAppliance.id)
                GestureDetector(
                  onTap: () {
                    widget.onApplianceChanged(_selected);
                    widget.onDismiss();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: KioskColors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: KioskColors.primary.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Text(
                      '적용',
                      style: TextStyle(
                        fontSize: 13,
                        color: KioskColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );

  Widget _buildNodeSection() {
    final registered = _nodes[_selected.id];
    final textEmpty = _urlCtrl.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel('ESP32 노드 — ${_selected.name}'),
            const Spacer(),
            if (registered != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: KioskColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: KioskColors.success.withValues(alpha: 0.35)),
                ),
                child: const Text(
                  '등록됨',
                  style: TextStyle(fontSize: 11, color: KioskColors.success),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: KioskColors.muted),
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFFAF7F2)),
                    decoration: InputDecoration(
                      hintText: '192.168.x.x  또는  http://...:8080',
                      hintStyle: const TextStyle(
                          fontSize: 12, color: KioskColors.muted),
                      filled: true,
                      fillColor: KioskColors.surface2,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: KioskColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: KioskColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color:
                                KioskColors.primary.withValues(alpha: 0.7)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _saving ? null : _save,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: _saving
                        ? KioskColors.surface2
                        : KioskColors.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _saving
                          ? KioskColors.border
                          : KioskColors.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Center(
                    child: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: KioskColors.muted),
                          )
                        : Text(
                            textEmpty && registered != null ? '해제' : '저장',
                            style: TextStyle(
                              fontSize: 13,
                              color: _saving
                                  ? KioskColors.muted
                                  : KioskColors.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        if (_saveError != null) ...[
          const SizedBox(height: 8),
          Text(
            _saveError!,
            style: const TextStyle(fontSize: 11, color: KioskColors.danger),
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: KioskColors.muted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w400,
        ),
      );
}
