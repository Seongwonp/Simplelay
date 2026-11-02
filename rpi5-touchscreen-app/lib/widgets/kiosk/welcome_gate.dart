/// 첫 환영 화면을 띄울지 정하는 규칙. 근거는 본체의 '연결된 휴대폰 수'([readPhones]) 하나다.
///
/// 0을 확인했을 때만 뜬다. 모름(null)은 0이 아니다 — 쓰던 본체가 네트워크 문제로 초기 화면이 되면 안 된다.
/// 건너뛴 사실은 메모리에만 둔다(재부팅하면 아직 연결이 없을 때 다시 뜬다).
class KioskWelcomeGate {
  /// 떠 있는 동안 이만큼 연달아 모르면 닫는다. 한 번 놓쳤다고 닫으면 찍고 있던 코드가 사라진다.
  static const int unknownLimit = 3;

  bool showing = false;
  bool connected = false;
  bool closed = false;
  int _unknown = 0;

  /// 조회 결과를 반영한다. 환영 화면에서 지금 막 연결됐으면 true.
  bool readPhones(int? phones) {
    if (closed) return false;
    if (phones == null) {
      if (showing && ++_unknown >= unknownLimit) showing = false;
      return false;
    }
    _unknown = 0;
    if (phones == 0) {
      showing = true;
      return false;
    }
    if (showing) return markConnected();
    closed = true;
    return false;
  }

  bool markConnected() {
    if (connected) return false;
    connected = true;
    return true;
  }

  void close() {
    showing = false;
    closed = true;
  }
}
