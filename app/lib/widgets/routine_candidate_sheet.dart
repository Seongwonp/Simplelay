import 'package:flutter/material.dart';

import '../models/routine.dart';
import '../models/routine_candidate.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 루틴 초안 저장 확인(2026-10-14) — 새 화면이 아니라 아래에서 올라오는 시트다.
///
/// 가전·버튼 순서는 서버 초안 그대로 보여 주고 고치지 않는다(고치려면 저장 뒤 기존 편집기).
/// 사용자는 이름과 '직접 실행할 때만 / 정해진 때 물어보기'만 고른다. 기본은 '직접 실행할 때만'.
/// **저장만 한다** — 저장한 루틴을 돌려주고, 닫거나 취소하면 null(아무것도 저장하지 않는다).
Future<Routine?> showRoutineCandidateSheet(
  BuildContext context, {
  required RoutineCandidate candidate,
  required RpiApiService api,
}) {
  return showModalBottomSheet<Routine>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: SafeArea(child: _CandidateSheet(candidate: candidate, api: api)),
    ),
  );
}

class _CandidateSheet extends StatefulWidget {
  const _CandidateSheet({required this.candidate, required this.api});
  final RoutineCandidate candidate;
  final RpiApiService api;

  @override
  State<_CandidateSheet> createState() => _CandidateSheetState();
}

class _CandidateSheetState extends State<_CandidateSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.candidate.suggestedName);
  late String _run = widget.candidate.runChoices.first.$1;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '루틴 이름을 적어 주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final routine = await widget.api
          .saveRoutineCandidate(widget.candidate.key, name: name, run: _run);
      if (mounted) Navigator.pop(context, routine);
    } on RpiApiException catch (e) {
      if (mounted) {
        setState(() => _error =
            e.message.isNotEmpty ? e.message : '저장하지 못했어요. 연결을 봐 주세요.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '저장하지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.candidate;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('루틴으로 저장할까요?', style: AppText.heading),
          const SizedBox(height: 12),
          Text('${c.applianceName}: ${c.sequenceText}',
              key: const Key('candidate-sheet-sequence'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text(c.evidence, style: TextStyle(fontSize: 15, color: context.appMuted)),
          const SizedBox(height: 16),
          TextField(
            key: const Key('candidate-name'),
            controller: _name,
            maxLength: 30,
            decoration: const InputDecoration(labelText: '루틴 이름'),
          ),
          const SizedBox(height: 4),
          RadioGroup<String>(
            groupValue: _run,
            onChanged: (v) {
              if (!_saving) setState(() => _run = v ?? _run);
            },
            child: Column(
              children: [
                for (final (run, label) in c.runChoices)
                  RadioListTile<String>(
                    key: Key('candidate-run-$run'),
                    contentPadding: EdgeInsets.zero,
                    value: run,
                    title: Text(label),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(c.notice,
              key: const Key('candidate-notice'),
              style: TextStyle(fontSize: 15, color: context.appMuted)),
          if (_error case final message?) ...[
            const SizedBox(height: 8),
            Text(message,
                key: const Key('candidate-error'),
                style: TextStyle(fontSize: 15, color: context.appDanger)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('candidate-confirm'),
            onPressed: _saving ? null : _save,
            child: const Text('저장'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('candidate-cancel'),
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }
}
