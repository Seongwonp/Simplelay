import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/rpi_api_service.dart';

void main() {
  test('sensor provenance defaults to untrusted and preserves explicit real', () {
    expect(SensorReading.fromJson({'temperature': 26.5}).mocked, isTrue);
    expect(SensorReading.fromJson({'mocked': true, 'temperature': 26.5}).mocked, isTrue);
    expect(SensorReading.fromJson({'mocked': false, 'temperature': 26.5}).mocked, isFalse);
  });
  test('demo suggestion provenance is separate from its reason', () {
    final data = <String, dynamic>{'id': 's', 'purpose': 'test', 'time_band': '환경', 'occurrences': 0, 'is_demo': true};
    expect(RpiSuggestion.fromJson(data).isDemo, isTrue);
    data['is_demo'] = false;
    expect(RpiSuggestion.fromJson(data).isDemo, isFalse);
    data['time_band'] = '데모';
    expect(RpiSuggestion.fromJson(data).isDemo, isTrue);
  });
  test('old history never defaults to real', () {
    final data = <String, dynamic>{'job_id': 'j', 'finished_at': '2026-09-27T00:00:00Z', 'status': 'succeeded', 'retry_count': 0, 'buttons': []};
    expect(RpiHistoryEntry.fromJson(data).executionMode, 'unknown');
    data['execution_mode'] = 'mock';
    expect(RpiHistoryEntry.fromJson(data).executionMode, 'mock');
  });
}
