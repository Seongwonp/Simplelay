/// Read-only closed-list proposal, never an arbitrary URL or executable model text.
class IntentProposal {
  const IntentProposal(
      {required this.kind,
      required this.label,
      required this.question,
      this.applianceId,
      this.buttons = const [],
      this.action,
      this.args = const {},
      this.routineId,
      this.fingerprint});
  final String kind, label, question;
  final String? applianceId, action, routineId, fingerprint;
  final List<String> buttons;
  final Map<String, String> args;

  static IntentProposal? parse(Map<String, dynamic> json) {
    if (json['understood'] != true ||
        !['llm', 'rules'].contains(json['source'])) {
      return null;
    }
    final raw = json['action'];
    final label = json['label'];
    final question = json['question'];
    if (raw is! Map ||
        label is! String ||
        label.trim().isEmpty ||
        question is! String ||
        question.trim().isEmpty ||
        label.length > 300 ||
        question.length > 320) {
      return null;
    }
    final kind = raw['kind'];
    final aid = raw['appliance_id'];
    bool identifier(Object? s) =>
        s is String && s.isNotEmpty && s.length <= 64 && !s.contains('/');
    final buttons = raw['buttons'];
    final args = raw['args'];
    if (kind == 'buttons' &&
        identifier(aid) &&
        buttons is List &&
        buttons.isNotEmpty &&
        buttons.length <= 20 &&
        buttons.every((b) => b is String && b.trim().isNotEmpty)) {
      return IntentProposal(
          kind: kind,
          label: label,
          question: question,
          applianceId: aid as String,
          buttons: buttons.cast<String>());
    }
    if (kind == 'thinq' &&
        identifier(aid) &&
        raw['action'] is String &&
        args is Map &&
        args.isNotEmpty &&
        args.length <= 16 &&
        args.entries.every((e) => e.key is String && e.value is String)) {
      return IntentProposal(
          kind: kind,
          label: label,
          question: question,
          applianceId: aid as String,
          action: raw['action'] as String,
          args: Map<String, String>.from(args));
    }
    if (kind == 'routine' &&
        identifier(raw['routine_id']) &&
        raw['fingerprint'] is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['fingerprint'] as String)) {
      return IntentProposal(
          kind: kind,
          label: label,
          question: question,
          routineId: raw['routine_id'] as String,
          fingerprint: raw['fingerprint'] as String);
    }
    return null;
  }
}
