import 'package:flutter/material.dart';

import '../../models/kiosk_time.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 결과 화면을 닫은 뒤에도 남기는 '지난 일'(사용자 결정 10/18) — 실패·'확인 못 함'만. 성공은 남기지 않는다.
///
/// 키오스크 안에서만 기억한다(앱을 다시 켜면 사라진다). '확인'을 눌렀다는 사실을 서버가 갖고 있지 않아, 다시 켤 때 서버 결과로
/// 되살리면 이미 확인한 일이 다시 뜨거나 영영 안 뜨게 된다.
@immutable
class KioskPastResult {
  const KioskPastResult({required this.at, required this.label, required this.headline});

  /// 결과가 나온 시각.
  final DateTime at;

  /// 무엇이었는지(행동 이름 '즉석밥 데우기' 또는 가전 이름). 모르면 빈 문자열.
  final String label;

  /// 결과 화면의 큰 글자('눌렸는지 몰라요' · '보냈지만 됐는지 몰라요' 등).
  final String headline;

  /// '오후 3:12 즉석밥 데우기, 눌렸는지 몰라요'(평가 17차 10/18 — 긴 줄표 대신 쉼표). [now]를 주면 오늘이 아닐 때 날짜 말을 앞에
  /// 붙인다('어제 오후 3:12', '9월 30일 오후 3:12').
  String textAt(DateTime? now) {
    var when = clockTime(at.hour, at.minute);
    if (now != null) {
      final day = DateTime(at.year, at.month, at.day);
      final today = DateTime(now.year, now.month, now.day);
      final diff = today.difference(day).inDays;
      if (diff == 1) {
        when = '어제 $when';
      } else if (diff != 0) {
        when = '${at.month}월 ${at.day}일 $when';
      }
    }
    return label.isEmpty ? '$when, $headline' : '$when $label, $headline';
  }

  /// 날짜 말 없는 꼴(오늘 일).
  String get text => textAt(null);
}

/// 처음 화면 위 한 줄 — 앰버 줄·물음표 + 지난 일 + '확인'(누를 때까지 남는다). 화면을 덮지 않고 위에 줄을 더한다.
class KioskPastResultLine extends StatelessWidget {
  const KioskPastResultLine({super.key, required this.result, required this.onAcknowledge, this.now});

  /// 지금 시각 — 오늘이 아니면 날짜 말('어제')을 붙인다. 모르면 시각만.
  final DateTime? now;

  final KioskPastResult result;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final tone = KioskColors.warning;
    return Semantics(
      container: true,
      label: '지난 일. ${result.textAt(now)}',
      child: Container(
        key: const ValueKey('idle-past-result'),
        decoration: BoxDecoration(
          color: KioskColors.surface,
          border: Border(left: BorderSide(color: tone, width: KioskSizes.bandStripe)),
        ),
        padding: const EdgeInsets.fromLTRB(KioskSpace.md, 4, KioskSpace.sm, 4),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(Icons.help_outline, size: KioskSizes.bandIcon, color: tone)),
            const SizedBox(width: KioskSpace.xs),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  result.textAt(now),
                  key: const ValueKey('idle-past-result-text'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: KioskType.body, fontWeight: FontWeight.w600, height: 1.25, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(width: KioskSpace.sm),
            OutlinedButton(
              key: const ValueKey('idle-past-result-ok'),
              onPressed: onAcknowledge,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(88, 48),
                foregroundColor: Colors.white,
                side: BorderSide(color: KioskColors.muted, width: 1.5),
                padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KioskSizes.buttonRadius)),
              ),
              child: const Text('확인',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 사람이 가전을 보고 답한 기록 하나(휴리스틱 평가 10/18) — 결과 화면 '가전을 보고 알려 주세요'의 답.
///
/// 서버에 사람 확인을 남길 API가 아직 없어 키오스크 안에서만 기억한다(앱을 다시 켜면 사라진다). 서버 기록의 확인 수준은
/// 바꾸지 않는다 — 기계가 확인한 것과 사람이 본 것은 다른 사실이다.
@immutable
class KioskPersonCheck {
  const KioskPersonCheck({required this.at, required this.jobId, required this.label, required this.worked});

  /// 답한 시각.
  final DateTime at;

  /// 그 결과의 job(모르면 null).
  final String? jobId;

  /// 무엇이었는지(행동 이름 또는 가전 이름).
  final String label;

  /// true '움직였어요·켜졌어요', false '안 …' 뒤 '손으로 할게요'.
  final bool worked;
}

/// 키오스크 안에 남기는 사람 확인 기록 수.
const kPersonCheckKeep = 20;
