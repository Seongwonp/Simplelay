import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 'LG ThinQ 연결' 안의 구획: ThinQ 계정에서 찾은 가전과 기기별 '추가' (2026-10-13).
///
/// - 찾기만으로는 아무것도 홈에 올리지 않는다. **사용자가 '추가'를 누를 때만** 허브에
///   추가하고, 추가해도 실행은 종전처럼 승인 카드를 거친다.
/// - 지원 안 함·상태만인 가전은 버튼 대신 이유 한 줄.
/// - 조회 실패(토큰·연결 끊김·허브 꺼짐)는 '0대'가 아니라 그 이유를 말한다. 정말
///   등록된 가전이 없을 때만 0대라고 말한다.
class ThinqDiscoveredSection extends ConsumerStatefulWidget {
  const ThinqDiscoveredSection({super.key});

  @override
  ConsumerState<ThinqDiscoveredSection> createState() =>
      _ThinqDiscoveredSectionState();
}

class _ThinqDiscoveredSectionState
    extends ConsumerState<ThinqDiscoveredSection> {
  final Set<String> _busy = {};

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(thinqDiscoveryProvider);
    final data = async.valueOrNull;
    final marker = data == null
        ? ''
        : data.mockCloud
            ? ' (연습)'
            : data.executionMode == 'mock'
                ? ' (연습)'
                : '';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LG 앱에서 찾은 가전$marker',
            style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '추가한 가전만 홈과 루틴에 나와요. 바꿀 때마다 한 번 물어봐요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const SizedBox(height: AppSpace.sm),
          if (async.isLoading && data == null)
            const Text('LG 앱에서 가전을 찾는 중이에요…',
                key: Key('thinq-found-loading'))
          else if (data == null || !data.ok)
            _failure(context, data?.failure ?? 'LG 가전 목록을 불러오지 못했어요.')
          else if (data.devices.isEmpty)
            const Text(
              'LG 앱에 등록된 가전이 없어요. LG 앱에서 가전을 먼저 등록해 주세요.',
              key: Key('thinq-found-empty'),
            )
          else
            for (final d in data.devices) _row(context, d),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context, String reason) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '가전을 찾지 못했어요. $reason',
            key: const Key('thinq-found-failure'),
            style: TextStyle(fontSize: AppFont.caption, color: context.appDanger),
          ),
          TextButton.icon(
            onPressed: () => ref.invalidate(thinqDiscoveryProvider),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('다시 찾기'),
          ),
        ],
      );

  Widget _row(BuildContext context, RpiThinqFound d) {
    final busy = _busy.contains(d.key);
    // 모델 코드(예: 영문 제품 코드)는 사용자에게 뜻이 없어 보이지 않는다. 종류가 이름과 같으면 줄을 생략한다
    // (외부 평가 10/16 p09).
    final kind = d.kindLabel == d.title ? '' : d.kindLabel;
    final String note;
    Color? noteColor;
    if (d.added) {
      note = d.source == 'config'
          ? '설치할 때 넣은 가전이에요'
          : '추가한 가전이에요. 홈과 루틴에 나와요';
      noteColor = context.appSuccess;
    } else if (d.canAdd) {
      note = d.supportReason;
      noteColor = context.appMuted;
    } else {
      note = d.reason ?? d.supportReason;
      noteColor = context.appMuted;
    }
    Widget? action;
    if (d.added && d.source == 'added') {
      // 테두리 있는 버튼 — 글자만 있으면 누를 곳으로 보이지 않는다(외부 평가 10/16 p09).
      action = OutlinedButton(
        key: Key('thinq-remove-${d.key}'),
        onPressed: busy ? null : () => _remove(d),
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
        child: const Text('빼기'),
      );
    } else if (!d.added && d.canAdd) {
      action = FilledButton(
        key: Key('thinq-add-${d.key}'),
        onPressed: busy ? null : () => _add(d),
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        child: Text(busy ? '추가 중' : '추가'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.title,
                    style: const TextStyle(
                        fontSize: AppFont.caption, fontWeight: FontWeight.w600)),
                if (kind.isNotEmpty)
                  Text(kind,
                      style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                Text(note,
                    key: Key('thinq-note-${d.key}'),
                    style: TextStyle(fontSize: AppFont.caption, color: noteColor)),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: AppSpace.sm), action],
        ],
      ),
    );
  }

  Future<void> _add(RpiThinqFound d) async {
    final api = ref.read(rpiApiServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (api == null) return;
    setState(() => _busy.add(d.key));
    try {
      final name = await api.addThinqDevice(d.key);
      messenger.showSnackBar(SnackBar(
          content: Text("'${name.isEmpty ? d.title : name}' 추가했어요. 홈에 나와요. "
              '바꿀 때는 한 번 물어봐요.')));
    } on RpiApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      await _refreshAll();
      if (mounted) setState(() => _busy.remove(d.key));
    }
  }

  Future<void> _remove(RpiThinqFound d) async {
    final api = ref.read(rpiApiServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (api == null) return;
    setState(() => _busy.add(d.key));
    try {
      await api.removeThinqDevice(d.key);
      messenger.showSnackBar(
          SnackBar(content: Text("'${d.name ?? d.title}' 뺐어요. 홈에서 사라져요.")));
    } on RpiApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      await _refreshAll();
      if (mounted) setState(() => _busy.remove(d.key));
    }
  }

  /// 찾은 목록·ThinQ 요약·홈 가전 목록을 함께 다시 받는다 — 추가한 가전이
  /// 홈 타일·루틴 대상에 바로 나오게.
  Future<void> _refreshAll() async {
    if (!mounted) return;
    ref.invalidate(thinqDiscoveryProvider);
    ref.invalidate(thinqOverviewProvider);
    await ref.read(serverApplianceCatalogProvider.notifier).refresh();
  }
}
