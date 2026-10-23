import 'package:flutter/material.dart';

import '../../theme/kiosk_tokens.dart';

import '../../models/appliance.dart';
import '../../models/kiosk_time.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_timings.dart';
import 'kiosk_text.dart';
import 'pairing_view.dart';
import '../learning_status_dialog.dart';

// 설정 진입: 대기 화면 우하단 상태 dot 3번 연속 탭
class KioskSettingsOverlay extends StatefulWidget {
  const KioskSettingsOverlay({
    super.key,
    required this.currentAppliance,
    this.appliances = kAppliances,
    required this.api,
    required this.onDismiss,
    this.ttsEnabled = true,
    this.onTtsChanged,
    this.largeTextEnabled = false,
    this.onLargeTextChanged,
    this.highContrastEnabled = false,
    this.onHighContrastChanged,
    this.darkModeEnabled = false,
    this.onDarkModeChanged,
    this.countdownSeconds = KioskTimings.countdownSeconds,
    this.onCountdownChanged,
    this.quietSchedule,
  });

  final ApplianceMap currentAppliance;

  /// 서버 가전 목록(내장+커스텀) — 노드 등록 대상 선택에 쓴다.
  /// "어느 가전을 조작할까"는 이제 설정이 아니라 수동 조작 진입 화면의 몫이다.
  final List<ApplianceMap> appliances;
  final KioskApiService api;
  final VoidCallback onDismiss;

  /// 음성 안내(espeak-ng) 켜짐 여부 + 토글 콜백
  final bool ttsEnabled;
  final ValueChanged<bool>? onTtsChanged;

  /// 큰 글씨 모드 켜짐 여부 + 토글 콜백
  final bool largeTextEnabled;
  final ValueChanged<bool>? onLargeTextChanged;

  /// 고대비 켜짐 여부 + 토글 콜백(사용자 결정 10/18)
  final bool highContrastEnabled;
  final ValueChanged<bool>? onHighContrastChanged;

  /// 어두운 화면 켜짐 여부 + 토글 콜백(시안 B 10/24). 기본은 밝은 화면.
  final bool darkModeEnabled;
  final ValueChanged<bool>? onDarkModeChanged;

  /// 제안 카드 자동 닫힘 시간(초) + 변경 콜백
  final int countdownSeconds;
  final ValueChanged<int>? onCountdownChanged;

  /// 켜 둔 매일 조용한 시간대 (시작, 끝) — 보여 주기만 한다(바꾸기는 휴대폰 앱 설정). null이면 정해 두지 않았다.
  /// 방해 금지(지금부터 잠깐)는 메뉴 한 곳에만 둔다 — 두 곳에 있으면 같은 기능인지 헷갈린다(사용자 결정 10/19).
  final (String, String)? quietSchedule;

  @override
  State<KioskSettingsOverlay> createState() => _KioskSettingsOverlayState();
}

class _KioskSettingsOverlayState extends State<KioskSettingsOverlay> {
  late ApplianceMap _selected;
  Map<String, String> _nodes = {};
  bool _loading = true;
  bool _showLearning = false;
  bool _showPairing = false;
  bool _saving = false;
  String? _saveError;
  late TextEditingController _urlCtrl;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentAppliance;
    _urlCtrl = TextEditingController()..addListener(() => setState(() {}));
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
      _saveError = ok ? null : '저장하지 못했어요. 본체 연결을 봐 주세요';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showPairing) {
      return KioskPairingView(api: widget.api, onClose: () => setState(() => _showPairing = false));
    }
    if (_showLearning) {
      // Keep the dialog inside KioskCanvas and the large-text MediaQuery.
      return ColoredBox(
        color: const Color(0xCC0C0E12),
        child: LearningStatusDialog(
          load: widget.api.learningStatus,
          applianceNames: {for (final a in widget.appliances) a.id: a.displayName},
          onClose: () => setState(() => _showLearning = false),
        ),
      );
    }
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
              // 800x480 화면 + 큰 글씨 모드에서도 오버플로하지 않게
              // 내용을 스크롤 가능하게 둔다 (헤더는 고정)
              constraints: const BoxConstraints(maxHeight: 430),
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
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.qr_code),
                            label: const Text('휴대폰 연결하기'),
                            onPressed: () => setState(() => _showPairing = true),
                          ),
                          const SizedBox(height: 16),
                          TextButton.icon(
                            icon: const Icon(Icons.history),
                            label: const Text('생활 습관 알아가기'),
                            onPressed: () => setState(() => _showLearning = true),
                          ),
                          const SizedBox(height: 16),
                          _buildQuietSection(),
                          const SizedBox(height: 16),
                          _buildTtsSection(),
                          const SizedBox(height: 16),
                          Divider(color: KioskColors.border, height: 1),
                          const SizedBox(height: 16),
                          _buildApplianceSection(),
                          const SizedBox(height: 20),
                          Divider(color: KioskColors.border, height: 1),
                          const SizedBox(height: 20),
                          _buildNodeSection(),
                        ],
                      ),
                    ),
                  ),
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
          Text(
            '본체 화면 설정',
            style: TextStyle(
              fontSize: KioskType.caption,
              color: KioskColors.ink,
              fontWeight: FontWeight.w300,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: widget.onDismiss,
            child: Icon(Icons.close, color: KioskColors.muted, size: 20),
          ),
        ],
      );

  /// 조용한 시간(매일 정한 시간대) — 보여 주기만 한다. 범위는 서버 `SCOPE_TEXT`와 같다(새 제안·일반 안내 소리를 쉬고,
  /// 아직 시작하지 않은 자동으로 하는 일은 건너뛴다). 방해 금지는 다른 기능이라 메뉴를 가리키기만 한다.
  Widget _buildQuietSection() {
    final q = widget.quietSchedule;
    return Row(
      key: const ValueKey('settings-quiet'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.bedtime_outlined, color: KioskColors.muted, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '조용한 시간',
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.ink),
              ),
              KioskText(
                q == null
                    ? '정해 두지 않았어요. 휴대폰 앱 설정에서 정할 수 있어요.'
                    : '매일 ${spokenHhmm(q.$1)}부터 ${spokenHhmm(q.$2)}까지 새 제안과 일반 안내 소리를 쉬고, '
                        '자동으로 하는 일도 하지 않아요. 휴대폰 앱 설정에서 바꿀 수 있어요.',
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
              ),
              const SizedBox(height: 4),
              KioskText(
                "지금부터 잠깐만 쉬게 하려면 처음 화면 메뉴의 '방해 금지'를 눌러 주세요.",
                key: const ValueKey('settings-dnd-pointer'),
                style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTtsSection() => Column(
        children: [
          _toggleRow(
            icon: Icons.record_voice_over,
            title: '음성 안내',
            subtitle: '제안과 결과, 위험 경보를 소리로 읽어 줘요',
            value: widget.ttsEnabled,
            onChanged: widget.onTtsChanged,
          ),
          const SizedBox(height: 4),
          _toggleRow(
            icon: Icons.text_increase,
            title: '큰 글씨',
            subtitle: '화면 글자를 22% 크게 보여 줘요',
            value: widget.largeTextEnabled,
            onChanged: widget.onLargeTextChanged,
          ),
          const SizedBox(height: 4),
          // 고대비(사용자 결정 10/18) — 큰 글씨 바로 옆. 같은 파일에 저장된다.
          _toggleRow(
            key: const ValueKey('settings-high-contrast'),
            icon: Icons.contrast,
            title: '또렷하게 보기',
            subtitle: '글자와 테두리를 더 진하게 보여 줘요',
            value: widget.highContrastEnabled,
            onChanged: widget.onHighContrastChanged,
          ),
          const SizedBox(height: 4),
          // 밝은·어두운 화면(시안 B 10/24) — 같은 파일에 저장된다. 고대비를 켜면 고대비가 우선한다.
          _toggleRow(
            key: const ValueKey('settings-dark-mode'),
            icon: Icons.dark_mode_outlined,
            title: '어두운 화면',
            subtitle: '끄면 밝은 화면으로 보여 줘요',
            value: widget.darkModeEnabled,
            onChanged: widget.onDarkModeChanged,
          ),
          const SizedBox(height: 10),
          _buildCountdownRow(),
        ],
      );

  /// 제안 카드가 얼마나 오래 떠 있을지 — 걸어와서 읽고 판단할 시간이
  /// 사람마다 다르므로 고를 수 있어야 한다.
  Widget _buildCountdownRow() => Row(
        children: [
          Icon(Icons.timer_outlined, color: KioskColors.muted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '제안 표시 시간',
                  style: TextStyle(fontSize: KioskType.caption, color: KioskColors.ink),
                ),
                Text(
                  '제안 카드가 저절로 닫히기까지 걸리는 시간이에요',
                  style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
                ),
              ],
            ),
          ),
          ...KioskTimings.countdownChoices.map((seconds) {
            final selected = seconds == widget.countdownSeconds;
            return Padding(
              padding: const EdgeInsets.only(left: 6),
              child: SizedBox(
                height: 44,
                child: OutlinedButton(
                  onPressed: widget.onCountdownChanged == null
                      ? null
                      : () => widget.onCountdownChanged!(seconds),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        selected ? KioskColors.primary : KioskColors.muted,
                    backgroundColor: selected
                        ? KioskColors.primary.withValues(alpha: 0.14)
                        : null,
                    side: BorderSide(
                      color: selected
                          ? KioskColors.primary.withValues(alpha: 0.6)
                          : KioskColors.border,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    '$seconds초',
                    style: TextStyle(
                      fontSize: KioskType.caption,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      );

  Widget _toggleRow({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) =>
      Row(
        key: key,
        children: [
          Icon(icon, color: KioskColors.muted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style:
                      TextStyle(fontSize: KioskType.caption, color: KioskColors.ink),
                ),
                Text(
                  subtitle,
                  style:
                      TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: KioskColors.primary.withValues(alpha: 0.5),
            activeColor: KioskColors.primary,
            onChanged: onChanged,
          ),
        ],
      );

  /// 노드(ESP32 연결 장치)를 등록할 가전 고르기 — 조작할 가전을 바꾸는
  /// 자리가 아니다. 그 역할은 수동 조작 진입 화면으로 옮겼다: 설정 속 칩은
  /// "왜 여기 전자레인지가 떠 있지?"라는 맥락 없는 UI였고, 고령 사용자가
  /// 가전을 바꾸려면 숨은 설정(점 3연타 시절)을 찾아야 했다.
  Widget _buildApplianceSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('전기 플러그를 연결할 가전'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in widget.appliances)
                _applianceChip(a, isSelected: a.id == _selected.id),
            ],
          ),
        ],
      );

  Widget _applianceChip(ApplianceMap a, {required bool isSelected}) =>
      GestureDetector(
        onTap: () => _selectAppliance(a),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                color: isSelected ? KioskColors.primary : KioskColors.muted,
              ),
              const SizedBox(width: 7),
              Text(
                a.displayName,
                style: TextStyle(
                  fontSize: KioskType.caption,
                  color: isSelected
                      ? KioskColors.primary
                      : KioskColors.ink,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildNodeSection() {
    final registered = _nodes[_selected.id];
    final textEmpty = _urlCtrl.text.trim().isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel('${_selected.displayName} 전기 플러그'),
            const Spacer(),
            if (registered != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: KioskColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: KioskColors.success.withValues(alpha: 0.35)),
                ),
                child: Text(
                  '등록했어요',
                  style: TextStyle(fontSize: KioskType.caption, color: KioskColors.success),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_loading)
          Center(
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
                    style:
                        TextStyle(fontSize: KioskType.caption, color: KioskColors.ink),
                    decoration: InputDecoration(
                      hintText: '192.168.x.x  또는  http://...:8080',
                      hintStyle: TextStyle(
                          fontSize: KioskType.caption, color: KioskColors.muted),
                      filled: true,
                      fillColor: KioskColors.surface2,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: KioskColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: KioskColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: KioskColors.primary.withValues(alpha: 0.7)),
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
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: KioskColors.muted),
                          )
                        : Text(
                            textEmpty && registered != null ? '지우기' : '저장',
                            style: TextStyle(
                              fontSize: KioskType.caption,
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
            style: TextStyle(fontSize: KioskType.caption, color: KioskColors.danger),
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
        style: TextStyle(
          fontSize: KioskType.caption,
          color: KioskColors.muted,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w400,
        ),
      );
}
