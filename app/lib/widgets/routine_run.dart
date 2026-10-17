import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/rpi_api_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/rpi_api_service.dart';

/// 루틴 '실행' — **승인 카드를 만들 뿐이다**(편집기 '지금 실행'·루틴 목록·홈이 함께 쓴다).
///
/// triggerRoutine → 제안 목록 새로 고침 → 승인 화면(`/suggestion/{id}`). 가전을
/// 누르는 일은 그 화면의 최종 승인에서만 일어난다. 알림만 루틴이면 카드가 없고
/// 알림만 보냈다고 알린다.
///
/// 돌려주는 값: 화면에 보일 오류 문장(없으면 null). 호출자가 busy를 쥐고 중복 탭을 막는다.
Future<String?> runRoutineNow(
  BuildContext context,
  WidgetRef ref,
  String routineId,
) async {
  final api = ref.read(rpiApiServiceProvider);
  if (api == null) return '본체와 연결되면 할 수 있어요.';
  try {
    final result = await api.triggerRoutine(routineId);
    if (!context.mounted) return null;
    final cardId = result.suggestionId;
    if (cardId != null) {
      await ref.read(suggestionProvider.notifier).refresh();
      if (context.mounted) context.push('/suggestion/$cardId');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('알림만 보냈어요. 가전은 그대로예요.')));
    }
    return null;
  } on RpiApiException catch (e) {
    return routineRunErrorText(e);
  } catch (_) {
    return '카드를 만들지 못했어요. 연결을 봐 주세요.';
  }
}

/// 실행 요청 실패를 사람 말로. 서버 문장(409 '지금은 루틴 카드를 만들 수 없어요: …',
/// 412 준비 안 됨)은 이미 한국어라 그대로 쓴다. 지워진 루틴(404)만 할 일을 붙인다.
String routineRunErrorText(RpiApiException e) {
  if (e.statusCode == 404) return '이 루틴을 찾지 못했어요. 목록을 새로 고쳐 주세요.';
  final message = e.message.trim();
  if (message.isNotEmpty) return message;
  return switch (e.statusCode) {
    409 => '다른 일을 하는 중이에요. 끝난 뒤 다시 눌러 주세요.',
    412 => '가전이 아직 준비되지 않았어요.',
    _ => '카드를 만들지 못했어요. 연결을 봐 주세요.',
  };
}
