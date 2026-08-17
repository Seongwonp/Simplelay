import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/photo_service.dart';

final photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());
