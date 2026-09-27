import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

void main() {
  test('sensor provenance defaults to untrusted and preserves explicit real', () {
    expect(SensorData.fromJson({'temperature': 26.5}).mocked, isTrue);
    expect(SensorData.fromJson({'mocked': true, 'temperature': 26.5}).mocked, isTrue);
    expect(SensorData.fromJson({'mocked': false, 'temperature': 26.5}).mocked, isFalse);
  });
  test('demo suggestion provenance is separate from its reason', () {
    final data = <String, dynamic>{'id': 's', 'purpose': 'test', 'time_band': '환경', 'occurrences': 0, 'is_demo': true};
    expect(KioskSuggestion.fromJson(data).isDemo, isTrue);
    data['is_demo'] = false;
    expect(KioskSuggestion.fromJson(data).isDemo, isFalse);
    data['time_band'] = '데모';
    expect(KioskSuggestion.fromJson(data).isDemo, isTrue);
  });
}
