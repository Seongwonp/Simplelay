import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import 'routine_confirm_sheet.dart';
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
    return '물어보는 화면을 띄우지 못했어요. 본체 연결을 보고 다시 눌러 주세요.';
  }
}

/// '지금 하기'의 공통 입구(휴리스틱 평가 10/18) — 무엇을 하는지 한 번 묻고([showRoutineRunConfirm]), 고르면
/// [runRoutineNow](승인 카드 → 승인 화면, 경로 그대로). 취소하면 아무것도 보내지 않고 null.
/// 홈 루틴 줄·루틴 탭·루틴 편집기·기록 '다시 해 보기'가 모두 이 길을 탄다.
Future<String?> confirmAndRunRoutine(
  BuildContext context,
  WidgetRef ref,
  Routine routine, {
  VoidCallback? onConfirmed,
}) async {
  final id = routine.id;
  if (id == null) return null;
  final ok = await showRoutineRunConfirm(
    context,
    routine: routine,
    appliances: ref.read(installedAppliancesProvider),
    // 홈 타일 '!'와 같은 근거(본체 목록의 같은 id 판정) — 이 폰에 저장한 정의는 판정을 들고 있지 않다.
    readinessOf: ref.read(serverApplianceCatalogProvider).readinessFor,
  );
  if (!ok || !context.mounted) return null;
  // 고른 뒤부터 '요청 중'(부르는 쪽이 단추를 잠그고 진행 표시) — 묻는 동안에는 돌지 않는다.
  onConfirmed?.call();
  return runRoutineNow(context, ref, id);
}

/// 실행 요청 실패를 사람 말로. 서버 문장(409 '지금은 루틴 카드를 만들 수 없어요: …',
/// 412 준비 안 됨)은 이미 한국어라 그대로 쓴다. 지워진 루틴(404)만 할 일을 붙인다.
String routineRunErrorText(RpiApiException e) {
  if (e.statusCode == 404) return '이 루틴을 찾지 못했어요. 루틴 화면에서 아래로 당겨 목록을 새로 봐 주세요.';
  final message = e.message.trim();
  if (message.isNotEmpty) return message;
  return switch (e.statusCode) {
    409 => '다른 일을 하고 있어요. 끝난 뒤 다시 눌러 주세요.',
    412 => '가전이 아직 준비되지 않았어요. 가전 화면에서 남은 설정을 봐 주세요.',
    _ => '물어보는 화면을 띄우지 못했어요. 본체 연결을 보고 다시 눌러 주세요.',
  };
}
