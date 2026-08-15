import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/voice_service.dart';

final voiceServiceProvider = Provider<VoiceService>((ref) => VoiceService());

final voiceTextProvider = StateProvider<String>((ref) => '');
final voiceListeningProvider = StateProvider<bool>((ref) => false);
