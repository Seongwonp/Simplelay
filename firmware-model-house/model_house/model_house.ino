// 집 모형(ESP8266) — 본체(RPi5)의 GET /model/state 를 1초마다 읽어 조명·선풍기·실링팬·LCD를 맞춘다.
// 본체가 '무장'한 동안(발표 슬라이드의 사람 감지 장)만 사람 감지를 따르고, 그 밖에는 모두 꺼진 대기 상태다.
// 본체에 닿지 못하면 FAIL_OFF 번 연속 실패 뒤 모두 끈다(마지막 상태로 계속 켜 두지 않는다).
//
// 필요한 라이브러리: ESP8266 보드 패키지, ArduinoJson(6.x), LiquidCrystal_I2C.
// 와이파이·본체 주소·키는 secrets.h(저장소에 올리지 않음, secrets.h.example 참고).
// 핀은 아래 PIN_* 를 실제 배선에 맞춘다. 팬은 트랜지스터·모터 드라이버를 거쳐 연결한다(핀에서 직접 모터 전류를 끌지 않는다).

#include <ESP8266WiFi.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>

#include "secrets.h"  // WIFI_SSID, WIFI_PASS, HUB_URL("http://<본체 주소>:8000"), HUB_KEY

const uint8_t PIN_LIGHT = D5;
const uint8_t PIN_FAN = D6;
const uint8_t PIN_CEILING_FAN = D7;
const uint8_t LCD_ADDR = 0x27;  // 안 뜨면 0x3F
const unsigned long POLL_MS = 1000;
const int FAIL_OFF = 5;

LiquidCrystal_I2C lcd(LCD_ADDR, 16, 2);
String shown1, shown2;
int failures = 0;

void setOutputs(bool light, bool fan, bool ceiling) {
  digitalWrite(PIN_LIGHT, light ? HIGH : LOW);
  digitalWrite(PIN_FAN, fan ? HIGH : LOW);
  digitalWrite(PIN_CEILING_FAN, ceiling ? HIGH : LOW);
}

void showLcd(const String& l1, const String& l2) {
  if (l1 == shown1 && l2 == shown2) return;  // 같은 글이면 다시 그리지 않는다(깜빡임 방지)
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print(l1);
  lcd.setCursor(0, 1);
  lcd.print(l2);
  shown1 = l1;
  shown2 = l2;
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  showLcd("SimpleLay", "WiFi...");
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) delay(250);
}

bool poll() {
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(1500);
  if (!http.begin(client, String(HUB_URL) + "/model/state")) return false;
  http.addHeader("X-API-Key", HUB_KEY);
  int code = http.GET();
  if (code != 200) {
    http.end();
    return false;
  }
  StaticJsonDocument<512> doc;
  DeserializationError err = deserializeJson(doc, http.getString());
  http.end();
  if (err) return false;
  setOutputs(doc["light"] | false, doc["fan"] | false, doc["ceiling_fan"] | false);
  showLcd(String((const char*)(doc["lcd1"] | "")), String((const char*)(doc["lcd2"] | "")));
  return true;
}

void setup() {
  pinMode(PIN_LIGHT, OUTPUT);
  pinMode(PIN_FAN, OUTPUT);
  pinMode(PIN_CEILING_FAN, OUTPUT);
  setOutputs(false, false, false);
  Wire.begin();  // NodeMCU 기본 SDA=D2, SCL=D1
  lcd.init();
  lcd.backlight();
  showLcd("SimpleLay", "Starting...");
  connectWifi();
}

void loop() {
  connectWifi();
  if (poll()) {
    failures = 0;
  } else if (++failures >= FAIL_OFF) {
    setOutputs(false, false, false);
    showLcd("SimpleLay", "Hub offline");
  }
  delay(POLL_MS);
}
