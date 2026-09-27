import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import 'rpi_api_provider.dart';

/// 서버 가전 목록 조회의 **상태**. 세 가지를 섞지 않기 위한 값이다.
///
/// - `loaded`이면서 비어 있음 = 서버에 정말 내장 가전이 없다.
/// - `failed` = 조회 자체가 안 됐다. "없다"가 아니라 "모른다"다.
/// - 데모 표본은 여기와 무관하다 -- 설정에서 켠 앱 데모 모드가 따로 정한다.
enum ServerCatalogStatus {
  /// 서버 주소가 없다.
  unconfigured,

  /// 조회 중이다. 이전 서버의 목록은 이미 비웠다.
  loading,

  /// 조회가 성공했다(빈 목록도 성공이다).
  loaded,

  /// 조회가 실패했다(연결 불가·오류 응답).
  failed,
}

/// 서버가 제공하는 **내장 가전**(is_custom=false)만 담는 목록.
///
/// 사용자 등록 가전은 여기 없다 -- 그쪽은 `customAppliancesProvider`가 들고
/// 있고 동기화 대기열(PUT/DELETE)의 대상이다. 서버 내장 가전은 이 폰이
/// 편집·저장·삭제할 것이 아니므로 기기 저장소에도 대기열에도 넣지 않는다.
///
/// `baseUrl`은 이 목록이 **어느 서버의 것**인지 말한다. 주소가 바뀌면 목록은
/// 그 즉시 비워지고, 새 주소의 응답이 올 때까지 이전 서버의 가전을 보여주지
/// 않는다.
@immutable
class ServerApplianceCatalog {
  const ServerApplianceCatalog({
    required this.status,
    this.baseUrl,
    this.appliances = const [],
  });

  static const empty = ServerApplianceCatalog(
    status: ServerCatalogStatus.unconfigured,
  );

  final ServerCatalogStatus status;
  final String? baseUrl;

  /// 서버 내장 가전만. 사용자 등록 가전은 걸러져 있다.
  final List<ApplianceMap> appliances;

  bool get isLoading => status == ServerCatalogStatus.loading;
  bool get isFailed => status == ServerCatalogStatus.failed;
  bool get isLoaded => status == ServerCatalogStatus.loaded;
}

/// 서버 내장 가전 목록을 조회·보관한다.
///
/// 세 가지 오염을 막는다.
///
/// 1. **서버 변경**: 주소가 바뀌면 목록을 먼저 비운다. 그래야 A 서버의
///    전자레인지를 B 서버에서 조작하는 화면이 생기지 않는다.
/// 2. **늦은 응답**: 요청마다 세대 번호를 찍는다. A에 보낸 요청이 B 목록이
///    자리 잡은 뒤에 도착하면 버린다 -- 안 그러면 이전 서버의 목록이 새
///    서버 목록을 덮는다.
/// 3. **실패와 빈 목록**: 조회 실패는 `failed`로 남고 목록은 비어 있다. 빈
///    성공 응답은 `loaded`다. 화면은 이 둘을 다르게 말할 수 있다.
class ServerApplianceNotifier extends StateNotifier<ServerApplianceCatalog> {
  ServerApplianceNotifier(this._ref) : super(ServerApplianceCatalog.empty) {
    // 서비스·연결 provider와의 연결은 **첫 프레임 뒤**에 맺는다. 생성 시점에
    // 바로 맺으면 주소 저장소 읽기가 화면이 붙기 전에 시작되고, 그 갱신이
    // 프레임 대신 타이머로 예약되어 위젯 테스트의 잔여 타이머 검사에 걸린다.
    // 실제 앱에서도 첫 프레임 전의 조회는 아무도 보지 못한다. 위젯 바인딩이
    // 없는 순수 단위 테스트에서는 즉시 맺는다.
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => start());
    } catch (_) {
      start();
    }
  }

  /// 테스트 전용 -- 서버 없이 목록을 고정한다. 아무것도 듣지 않는다.
  @visibleForTesting
  ServerApplianceNotifier.seeded(this._ref, ServerApplianceCatalog catalog)
      : super(catalog) {
    _started = true;
  }

  final Ref _ref;

  /// 요청 세대. 응답이 돌아왔을 때 이 값이 바뀌어 있으면 그 응답은 이미
  /// 다른 서버(또는 더 새 요청)에 밀린 것이다.
  int _generation = 0;
  bool _started = false;

  /// 서비스·연결 변화를 듣기 시작하고, 서비스가 이미 있으면 첫 조회를 한다.
  ///
  /// 생성자가 첫 프레임 뒤에 부른다. 프레임이 없는 단위 테스트는 직접 부른다.
  /// 두 번 불러도 한 번만 맺는다.
  @visibleForTesting
  void start() {
    if (_started || !mounted) return;
    _started = true;
    // 서비스가 바뀌는 모든 경우(주소·API 키·데모 모드·클라이언트)에 다시
    // 조회한다. 앱 시작 시에는 주소가 기기에서 올라오며 서비스가 null에서
    // 값으로 바뀌므로 그때 첫 조회가 일어난다. 이 알림은 다른 provider의
    // 재계산 도중(화면 빌드 중일 수 있다)에 오므로 상태 변경은 마이크로태스크로
    // 한 박자 미룬다.
    _ref.listen<Object?>(rpiApiServiceProvider, (_, __) => _refreshSoon());
    // 연결이 끊겼다 돌아오면 **성공했던 목록도** 다시 받는다. 끊긴 사이에
    // 가전이 바뀌었거나 준비 상태(can_execute·readiness)가 달라졌을 수 있고,
    // 그것을 옛 목록으로 계속 보여주면 안 되는 버튼을 누를 수 있게 둔다.
    // 늦은 응답은 세대 번호로 계속 버린다.
    _ref.listen<RpiConnectionState>(rpiConnectionProvider, (prev, next) {
      if (next == RpiConnectionState.connected &&
          prev != RpiConnectionState.connected) {
        _refreshSoon();
      }
    });
    if (_ref.read(rpiApiServiceProvider) != null) _refreshSoon();
  }

  void _refreshSoon() {
    Future.microtask(() {
      if (mounted) refresh();
    });
  }

  /// 현재 서버에서 목록을 다시 받는다. 겹쳐 불러도 마지막 요청만 남는다.
  Future<void> refresh() async {
    final generation = ++_generation;
    final api = _ref.read(rpiApiServiceProvider);
    if (api == null) {
      state = ServerApplianceCatalog.empty;
      return;
    }
    // 주소는 서비스에서 읽는다. 주소 provider를 따로 끌어오면 서비스만
    // 주입한 구성(테스트·데모)에서 기기 저장소 읽기가 덩달아 시작된다.
    final url = api.baseUrl;
    // 이전 서버의 목록은 **응답을 기다리지 않고** 비운다.
    state = ServerApplianceCatalog(
      status: ServerCatalogStatus.loading,
      baseUrl: url,
    );
    final result = await api.listAppliances();
    if (!mounted || generation != _generation) return; // 늦은 응답 -- 버린다
    if (result == null) {
      state = ServerApplianceCatalog(
        status: ServerCatalogStatus.failed,
        baseUrl: url,
      );
      return;
    }
    state = ServerApplianceCatalog(
      status: ServerCatalogStatus.loaded,
      baseUrl: url,
      // 서버 내장만. 사용자 등록 가전은 동기화 병합이 따로 받는다.
      appliances: [
        for (final a in result)
          if (!a.isCustom) a,
      ],
    );
  }
}

final serverApplianceCatalogProvider =
    StateNotifierProvider<ServerApplianceNotifier, ServerApplianceCatalog>(
  ServerApplianceNotifier.new,
);
