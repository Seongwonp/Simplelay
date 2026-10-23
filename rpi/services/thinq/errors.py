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

# 10/18 쉬운 말: 사람 말로 결과 한 줄 + 할 일 한 줄. 'ThinQ'·'PAT'·'API'·설정 이름·'—'·괄호를 쓰지 않는다
# (LG 가전 · LG 앱). 컨트롤러가 이유 바로 뒤에 결과('그래서 보내지 않았어요' 등)를 넣으므로 '이유. 할 일.' 모양으로 쓴다.
# 설치하는 분이 고칠 일(연결 열쇠·나라 설정·권한)은 '설치하신 분께' 알리게 한다. 오류 코드·이름은 오류 객체에 남는다.
#: 받았는지 모르는 오류의 할 일. 제어 전송 중이면 컨트롤러가 '보냈는지 확인하지 못했어요'로 따로 말한다(이 문장을 쓰지 않는다).
_UNSURE = "잠시 뒤 다시 해 주세요."
_TOKEN = "LG 계정 연결이 끊겼어요. 설치하신 분께 연결을 다시 해 달라고 해 주세요."
_DEVICE = "LG 계정에서 이 가전을 찾지 못했어요. LG 앱에 가전이 있는지 봐 주세요."
_FEATURE = "이 가전은 그 기능을 쓸 수 없어요."
_ALLOWED = "이 연결로는 이 기능을 쓸 수 없어요. 설치하신 분께 알려 주세요."

API_ERROR_REASONS: dict[str, str] = {
    "UNKNOWN_ERROR": "LG 쪽에서 알 수 없는 오류가 났어요. " + _UNSURE,
    "BAD_REQUEST": "LG 쪽에서 명령을 받지 않았어요.",
    "MISSING_PARAMETERS": "명령에 필요한 값이 빠져서 LG 쪽에서 받지 않았어요.",
    "UNACCEPTABLE_PARAMETERS": "LG 쪽에서 이 값을 받지 않았어요. 다른 값으로 해 주세요.",
    "INVALID_TOKEN": _TOKEN,
    "INVALID_TOKEN_AGAIN": _TOKEN,
    "NOT_FOUND_TOKEN": _TOKEN,
    "NOT_REGISTERED_USER": "LG 계정을 찾지 못했어요. LG 앱에 로그인돼 있는지 봐 주세요.",
    "NOT_FOUND_USER": "LG 계정을 찾지 못했어요. 설치하신 분께 알려 주세요.",
    "NOT_EXIST_DEVICE": _DEVICE,
    "NOT_OWNED_DEVICE": _DEVICE,
    "NOT_REGISTERED_DEVICE": _DEVICE,
    "INVALID_DEVICE_ID": _DEVICE,
    "INCORRECT_HEADER": "LG 연결 설정이 맞지 않아요. 설치하신 분께 알려 주세요.",
    "NOT_SUPPORTED_MODEL": _FEATURE,
    "NOT_SUPPORTED_FEATURE": _FEATURE,
    "NOT_PROVIDED_FEATURE": _FEATURE,
    "NOT_CONNECTED_DEVICE": "가전이 인터넷에 연결돼 있지 않아요. 가전 전원과 와이파이를 봐 주세요.",
    "NOT_ACCEPTABLE_TERMS": "LG 앱에서 약관에 동의해야 해요. 동의한 뒤 다시 해 주세요.",
    "NOT_ALLOWED_API": _ALLOWED,
    "NOT_ALLOWED_API_AGAIN": _ALLOWED,
    "EXCEEDED_API_CALLS": "LG 쪽에 요청이 너무 많았어요. 잠시 뒤에 직접 다시 해 주세요.",
    "NOT_SUPPORTED_COUNTRY": "LG 계정의 나라 설정이 맞지 않아요. 설치하신 분께 알려 주세요.",
    "NO_CONTROL_AUTHORITY": "이 가전을 움직일 권한이 없어요. 설치하신 분께 알려 주세요.",
    "INTERNAL_SERVER_ERROR": "LG 쪽에 오류가 났어요. " + _UNSURE,
    "INVALID_COMMAND_ERROR": "가전이 이 명령을 받지 않았어요.",
    "FAIL_DEVICE_CONTROL": "가전을 움직이지 못했다고 LG 쪽에서 알려 왔어요.",
    "DEVICE_RESPONSE_DELAY": "가전 답이 늦어요. 잠시 뒤 새로 봐 주세요.",
    "COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF": "가전의 원격 제어가 꺼져 있어요. 가전에서 원격 제어를 켜 주세요.",
    "COMMAND_NOT_SUPPORTED_IN_STATE": "가전이 지금은 이 명령을 받을 수 없어요.",
    "COMMAND_NOT_SUPPORTED_IN_ERROR": "가전에 오류가 있어 이 명령을 받을 수 없어요. 가전 화면을 봐 주세요.",
    "COMMAND_NOT_SUPPORTED_IN_POWER_OFF": "가전이 꺼져 있어 이 명령을 받을 수 없어요. 먼저 켜 주세요.",
    "COMMAND_NOT_SUPPORTED_IN_MODE": "가전의 지금 모드에서는 이 명령을 받을 수 없어요.",
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
        # 코드는 오류 객체(``code``)에 남기고 문장에는 내지 않는다(10/18 쉬운 말).
        reason = API_ERROR_REASONS["UNKNOWN_ERROR"]
        return ThinqTransportError(reason, code=code, name=None, reason=reason)
    reason = API_ERROR_REASONS[name]
    if name in UNCERTAIN:
        return ThinqTransportError(reason, code=code, name=name, reason=reason)
    if name in OFFLINE:
        return ThinqOfflineError(reason, code=code, name=name, reason=reason)
    return ThinqCommandRejected(code, reason, name=name, reason=reason)
