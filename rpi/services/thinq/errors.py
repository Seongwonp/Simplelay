"""ThinQ Connect 오류 코드 → 우리 오류 종류 + 사람 말 이유.

코드·이름은 공식 SDK(``thinqconnect`` 1.0.14) ``ThinQAPIErrorCodes``에서 옮겼다(SDK가 설치돼
있으면 ``test_thinq_sdk_profile``이 표가 같은지 대조한다). SDK의 ``ThinQAPIException``은
요청 헤더(``Authorization`` 포함)를 속성으로 들고 있으므로, **그 예외 객체를 넘기거나 로그에
남기지 않고** 여기서 만든 우리 오류로 바꾼다(``from None``으로 원인 연결도 끊는다).

종류(제어 결과 계약 §3과 맞춘다):

- ``ThinqTransportError`` -- 받았는지 **모른다**(서버 내부 오류·기기 응답 지연·알 수 없는 오류).
  제어였다면 접수 불명이고, 자동으로 다시 보내지 않는다.
- ``ThinqOfflineError`` -- 기기가 클라우드에 연결돼 있지 않다(실행 안 됨).
- ``ThinqCommandRejected`` -- 클라우드가 거절했다(인증·약관·국가·호출 한도·지원 안 함·원격 꺼짐 등).
  실행되지 않았다.
"""

from __future__ import annotations

from .client import ThinqClientError, ThinqCommandRejected, ThinqOfflineError, ThinqTransportError

#: 우리가 이름을 부르는 코드(SDK ``ThinQAPIErrorCodes``와 같은 값).
API_ERROR_CODES: dict[str, str] = {
    "UNKNOWN_ERROR": "0000",
    "BAD_REQUEST": "1000",
    "MISSING_PARAMETERS": "1101",
    "UNACCEPTABLE_PARAMETERS": "1102",
    "INVALID_TOKEN": "1103",
    "NOT_REGISTERED_USER": "1202",
    "NOT_EXIST_DEVICE": "1205",
    "NOT_OWNED_DEVICE": "1212",
    "NOT_REGISTERED_DEVICE": "1213",
    "INCORRECT_HEADER": "1216",
    "INVALID_TOKEN_AGAIN": "1218",
    "NOT_SUPPORTED_MODEL": "1219",
    "NOT_SUPPORTED_FEATURE": "1220",
    "NOT_CONNECTED_DEVICE": "1222",
    "INVALID_DEVICE_ID": "1224",
    "NOT_FOUND_TOKEN": "1302",
    "NOT_FOUND_USER": "1303",
    "NOT_ACCEPTABLE_TERMS": "1304",
    "NOT_ALLOWED_API": "1305",
    "EXCEEDED_API_CALLS": "1306",
    "NOT_SUPPORTED_COUNTRY": "1307",
    "NO_CONTROL_AUTHORITY": "1308",
    "NOT_ALLOWED_API_AGAIN": "1309",
    "INTERNAL_SERVER_ERROR": "2000",
    "NOT_PROVIDED_FEATURE": "2201",
    "INVALID_COMMAND_ERROR": "2207",
    "FAIL_DEVICE_CONTROL": "2208",
    "DEVICE_RESPONSE_DELAY": "2209",
    "COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF": "2301",
    "COMMAND_NOT_SUPPORTED_IN_STATE": "2302",
    "COMMAND_NOT_SUPPORTED_IN_ERROR": "2303",
    "COMMAND_NOT_SUPPORTED_IN_POWER_OFF": "2304",
    "COMMAND_NOT_SUPPORTED_IN_MODE": "2305",
}

_NAME_BY_CODE = {code: name for name, code in API_ERROR_CODES.items()}

_TOKEN = "ThinQ 토큰(PAT)이 유효하지 않아요 — 개발자 사이트에서 PAT를 다시 발급해 저장소 밖 파일에 넣어 주세요"
_DEVICE = "이 계정에서 그 기기를 찾지 못했어요 — 기기 ID와 ThinQ 앱 등록을 확인해 주세요"
_FEATURE = "이 모델은 그 기능을 지원하지 않아요 — 기기 프로필을 확인해 주세요"

API_ERROR_REASONS: dict[str, str] = {
    "UNKNOWN_ERROR": "ThinQ 클라우드가 알 수 없는 오류를 돌려줬어요 — 실행됐는지 몰라요. 가전을 직접 확인해 주세요",
    "BAD_REQUEST": "ThinQ 클라우드가 요청 형식을 받아들이지 않았어요",
    "MISSING_PARAMETERS": "ThinQ 요청에 필요한 값이 빠졌어요",
    "UNACCEPTABLE_PARAMETERS": "ThinQ 클라우드가 이 값을 받아들이지 않았어요 — 기기 프로필의 허용값을 확인해 주세요",
    "INVALID_TOKEN": _TOKEN,
    "INVALID_TOKEN_AGAIN": _TOKEN,
    "NOT_FOUND_TOKEN": _TOKEN,
    "NOT_REGISTERED_USER": "ThinQ 계정이 등록돼 있지 않아요 — ThinQ 앱 가입·로그인을 확인해 주세요",
    "NOT_FOUND_USER": "ThinQ 계정을 찾지 못했어요 — PAT를 발급한 계정을 확인해 주세요",
    "NOT_EXIST_DEVICE": _DEVICE,
    "NOT_OWNED_DEVICE": _DEVICE,
    "NOT_REGISTERED_DEVICE": _DEVICE,
    "INVALID_DEVICE_ID": _DEVICE,
    "INCORRECT_HEADER": "ThinQ 요청 머리글이 맞지 않아요 — 국가 코드와 클라이언트 ID 설정을 확인해 주세요",
    "NOT_SUPPORTED_MODEL": _FEATURE,
    "NOT_SUPPORTED_FEATURE": _FEATURE,
    "NOT_PROVIDED_FEATURE": _FEATURE,
    "NOT_CONNECTED_DEVICE": "가전이 클라우드에 연결돼 있지 않아요 — 전원과 Wi-Fi를 확인해 주세요",
    "NOT_ACCEPTABLE_TERMS": "ThinQ 약관 동의가 필요해요 — ThinQ 앱에서 약관에 동의한 뒤 다시 시도해 주세요",
    "NOT_ALLOWED_API": "이 토큰으로는 이 API를 쓸 수 없어요 — PAT 발급 때 고른 권한(범위)을 확인해 주세요",
    "NOT_ALLOWED_API_AGAIN": "이 토큰으로는 이 API를 쓸 수 없어요 — PAT 발급 때 고른 권한(범위)을 확인해 주세요",
    "EXCEEDED_API_CALLS": "ThinQ 호출 한도를 넘었어요 — 잠시 뒤 다시 시도해 주세요(자동으로 다시 보내지 않아요)",
    "NOT_SUPPORTED_COUNTRY": "이 국가 코드로는 ThinQ Connect를 쓸 수 없어요 — SIMPLELAY_THINQ_COUNTRY를 계정 국가로 맞춰 주세요",
    "NO_CONTROL_AUTHORITY": "이 기기를 제어할 권한이 없어요 — 기기를 등록한 계정의 PAT인지 확인해 주세요",
    "INTERNAL_SERVER_ERROR": "ThinQ 클라우드 내부 오류예요 — 실행됐는지 몰라요. 가전을 직접 확인해 주세요",
    "INVALID_COMMAND_ERROR": "가전이 이 명령을 받아들이지 않았어요",
    "FAIL_DEVICE_CONTROL": "가전 제어에 실패했다고 클라우드가 알려 왔어요",
    "DEVICE_RESPONSE_DELAY": "가전 응답이 늦어요 — 실행됐는지 몰라요. 잠시 뒤 상태를 다시 조회해 주세요",
    "COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF": "가전의 원격 제어(원격 시작)가 꺼져 있어요 — 가전 본체에서 원격 제어를 켜 주세요",
    "COMMAND_NOT_SUPPORTED_IN_STATE": "가전의 지금 상태에서는 이 명령을 쓸 수 없어요",
    "COMMAND_NOT_SUPPORTED_IN_ERROR": "가전에 오류가 있어 이 명령을 쓸 수 없어요 — 가전 화면을 확인해 주세요",
    "COMMAND_NOT_SUPPORTED_IN_POWER_OFF": "가전 전원이 꺼져 있어 이 명령을 쓸 수 없어요",
    "COMMAND_NOT_SUPPORTED_IN_MODE": "가전의 지금 모드에서는 이 명령을 쓸 수 없어요",
}

#: 받았는지 모르는 오류 -- 제어였다면 접수 불명.
UNCERTAIN = frozenset({"UNKNOWN_ERROR", "INTERNAL_SERVER_ERROR", "DEVICE_RESPONSE_DELAY"})
OFFLINE = frozenset({"NOT_CONNECTED_DEVICE"})


def error_from_api(code: str | None, name: str | None) -> ThinqClientError:
    """SDK 예외의 (code, error_name)만 받아 우리 오류를 만든다. 헤더·메시지는 받지 않는다."""
    code = str(code) if code is not None else "unknown"
    # SDK는 모르는 코드에 UNKNOWN_ERROR라는 이름을 붙인다 -- 코드로 다시 찾는다.
    name = _NAME_BY_CODE.get(code) or (name if name in API_ERROR_REASONS and name != "UNKNOWN_ERROR" else None)
    if name is None:
        # 모르는 코드: 거절이라고 단정하지 않는다(실행됐는지 모름).
        reason = f"ThinQ 클라우드가 알 수 없는 오류(코드 {code})를 돌려줬어요 — 실행됐는지 몰라요. 가전을 직접 확인해 주세요"
        return ThinqTransportError(reason, code=code, name=None, reason=reason)
    reason = API_ERROR_REASONS[name]
    if name in UNCERTAIN:
        return ThinqTransportError(reason, code=code, name=name, reason=reason)
    if name in OFFLINE:
        return ThinqOfflineError(reason, code=code, name=name, reason=reason)
    return ThinqCommandRejected(code, reason, name=name, reason=reason)
