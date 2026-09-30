import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// 폰 위치를 한 번 읽은 결과.
///
/// 거절·꺼짐·실패를 예외로 던지지 않고 값으로 돌려준다 -- 화면이 경우마다
/// 다른 문장(설정에서 켜 주세요 / 다시 시도해 주세요)을 말해야 한다.
sealed class LocationOutcome {
  const LocationOutcome();
}

class LocationFix extends LocationOutcome {
  const LocationFix(this.lat, this.lon);
  final double lat;
  final double lon;
}

/// 이번에 거절했다. 다시 물을 수 있다.
class LocationDenied extends LocationOutcome {
  const LocationDenied();
}

/// '다시 묻지 않기'로 거절했다. 폰 설정에서만 바꿀 수 있다.
class LocationDeniedForever extends LocationOutcome {
  const LocationDeniedForever();
}

/// 폰의 위치 서비스(GPS) 자체가 꺼져 있다.
class LocationServiceOff extends LocationOutcome {
  const LocationServiceOff();
}

class LocationFailed extends LocationOutcome {
  const LocationFailed();
}

/// 위치 권한·조회를 감싼다. 테스트에서 provider를 갈아 끼운다.
///
/// **대략 위치만 쓴다.** 날씨 예보는 5km 격자이고 서버도 약 1km로 줄여
/// 저장하므로, 정밀 위치를 요청할 이유가 없다.
abstract class LocationService {
  Future<LocationOutcome> currentLocation();

  /// 거절을 되돌리려면 폰 설정으로 가야 한다. 열었으면 true.
  Future<bool> openSettings();
}

class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationOutcome> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationServiceOff();
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
          return const LocationDenied();
        case LocationPermission.deniedForever:
          return const LocationDeniedForever();
        case LocationPermission.whileInUse:
        case LocationPermission.always:
        case LocationPermission.unableToDetermine:
          break;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return LocationFix(position.latitude, position.longitude);
    } catch (_) {
      return const LocationFailed();
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }
}

final locationServiceProvider =
    Provider<LocationService>((_) => GeolocatorLocationService());
