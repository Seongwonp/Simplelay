import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/care_events_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 보호자 알림함 — 실패·위험소리·긴급정지·안부 신호를 시간순으로.
///
/// 이 사건들은 그동안 키오스크(가전 옆 화면)에만 표시됐다. 정작 걱정하는
/// 보호자는 밖에 있는데 볼 방법이 없었다 — 실제 고독사 예방 서비스들이
/// "이상 신호를 담당자에게 알림"을 핵심으로 두는 이유와 같다.
class CareEventsScreen extends ConsumerStatefulWidget {
  const CareEventsScreen({super.key});

  @override
  ConsumerState<CareEventsScreen> createState() => _CareEventsScreenState();
}

class _CareEventsScreenState extends ConsumerState<CareEventsScreen> {
  @override
  void initState() {
    super.initState();
    // 화면을 연 순간 = 읽음. 프레임 뒤로 미뤄 build 중 상태 변경을 피한다.
    // refresh를 기다린 뒤에 읽음 처리해야 한다 — cascade로 이어 부르면
    // 목록이 아직 비어 있을 때 markAllSeen이 돌아 아무것도 읽음이 안 된다
    // (테스트가 실제로 잡아낸 결함).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(careEventsProvider.notifier);
      await notifier.refresh();
      await notifier.markAllSeen();
    });
  }

  Future<void> _reload() async {
    final notifier = ref.read(careEventsProvider.notifier);
    await notifier.refresh();
    await notifier.markAllSeen();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(careEventsProvider);
    final events = state.events;

    return Scaffold(
      appBar: AppBar(title: const Text('알림')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: Column(
          children: [
            // 지금 보고 있는 것이 최신인지부터 말한다. 이 알림함이 다루는
            // 것은 실행 실패·위험 신호음·안부 신호라, "못 받았다"를 "아무
            // 일 없다"로 읽게 두면 기능의 이유가 무너진다.
            if (state.status == CareInboxStatus.failed)
              _InboxNotice(
                icon: Icons.cloud_off,
                text: events.isEmpty
                    ? '알림을 불러오지 못했어요.'
                    : '새 알림을 확인하지 못했어요.',
                onRetry: _reload,
              ),
            if (state.status == CareInboxStatus.unconfigured)
              const _InboxNotice(
                icon: Icons.wifi_off,
                text: '기기와 연결되면 여기에 표시돼요.',
              ),
            Expanded(
              child: events.isEmpty
                  ? _EmptyBody(state: state)
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(20),
                      itemCount: events.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => i == events.length
                          ? _LastCheckedAt(at: state.lastLoadedAt)
                          : _CareEventCard(event: events[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// **받아왔는데** 0건일 때만 쓴다. 못 받은 경우는 위 배너가 말한다 —
/// 통신이 끊겨 못 본 것을 "아무 일 없다"로 읽으면 이 알림함의 이유가
/// 그대로 무너진다.
class _EmptyState extends StatelessWidget {
  const _EmptyState({this.at});

  final DateTime? at;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none,
                size: 52, color: context.appMuted),
            const SizedBox(height: 14),
            Text('아직 알림이 없어요', style: AppText.title),
            const SizedBox(height: 6),
            Text(
              '실행 실패·위험 신호음·안부 신호가 생기면\n여기에 모아 보여드려요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appMuted, fontSize: 14),
            ),
            const SizedBox(height: 10),
            _LastCheckedAt(at: at),
          ],
        ),
      );
}

/// 목록 위에 얹는 한 줄 — 실패·미설정처럼 "목록 자체의 상태"를 말한다.
class _InboxNotice extends StatelessWidget {
  const _InboxNotice({required this.icon, required this.text, this.onRetry});

  final IconData icon;
  final String text;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: context.appWarning.withValues(alpha: 0.14),
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: context.appWarning),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
            if (onRetry != null)
              TextButton(
                onPressed: () => onRetry!(),
                child: const Text('다시 불러오기'),
              ),
          ],
        ),
      );
}

/// 목록이 비었을 때. **왜 비었는지**에 따라 다른 말을 한다.
class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.state});

  final CareEventsState state;

  @override
  Widget build(BuildContext context) {
    // 스크롤 가능해야 당겨서 새로고침이 된다 — 비어 있을 때야말로 다시
    // 시도할 방법이 필요하다.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: switch (state.status) {
            CareInboxStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            // 실패·미설정은 위 배너가 이미 말했다. 여기서 "알림이 없어요"를
            // 반복하면 못 받은 것을 없는 것으로 단언하게 된다.
            CareInboxStatus.failed ||
            CareInboxStatus.unconfigured =>
              const SizedBox.shrink(),
            CareInboxStatus.ready => _EmptyState(at: state.lastLoadedAt),
          },
        ),
      ],
    );
  }
}

/// 언제까지의 정보인지. 실패한 뒤에도 남는다 — "언제 확인한 것인지"가
/// 곧 이 화면을 얼마나 믿어도 되는지다.
class _LastCheckedAt extends StatelessWidget {
  const _LastCheckedAt({required this.at});

  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final t = at;
    if (t == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '${_two(t.hour)}:${_two(t.minute)} 기준',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.appMuted, fontSize: 13),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class _CareEventCard extends StatelessWidget {
  const _CareEventCard({required this.event});

  final RpiCareEvent event;

  // 종류별 아이콘·색 — 색만으로 구분하지 않도록 아이콘을 항상 함께 쓴다
  (IconData, Color, String) _style(BuildContext context) =>
      switch (event.kind) {
        'danger_sound' => (
            Icons.warning_amber_rounded,
            context.appDanger,
            '위험 신호음'
          ),
        'execution_failed' => (
            Icons.error_outline,
            context.appWarning,
            '실행 실패'
          ),
        'emergency_stop' => (
            Icons.front_hand_outlined,
            context.appWarning,
            '긴급 정지'
          ),
        'quiet_routine' => (
            Icons.favorite_outline,
            context.appPrimary,
            '안부 신호'
          ),
        _ => (Icons.info_outline, context.appMuted, '알림'),
      };

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return sameDay ? '오늘 $hm' : '${t.month}월 ${t.day}일 $hm';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = _style(context);
    return Semantics(
      label: '$label. ${event.message}. ${_formatTime(event.occurredAt)}',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTime(event.occurredAt),
                        style: TextStyle(
                            fontSize: 13, color: context.appMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    event.message,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
