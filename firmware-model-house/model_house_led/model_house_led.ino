/*
 * ESP8266 (NodeMCU) - 시연용 집 모형 LED 4개
 *
 * 배선 (각 LED마다 220Ω 저항 하나씩)
 *   LED1 : D1 -> 220Ω -> LED(+), LED(-) -> GND
 *   LED2 : D2 -> 220Ω -> LED(+), LED(-) -> GND
 *   LED3 : D5 -> 220Ω -> LED(+), LED(-) -> GND
 *   LED4 : D6 -> 220Ω -> LED(+), LED(-) -> GND
 *   (D1, D2, D5, D6은 부팅 제약이 없는 안전한 핀)
 *
 * 본체 연동: 1초마다 본체 GET /model/state 를 읽는다. 본체가 'light'를 바꾸면(발표 장에서 무장 + 사람 있음)
 * 한 번 흐르기를 보여 준 뒤 전체를 켜고, 꺼지면 전체를 끈다. 상태가 바뀔 때만 적용하므로
 * 그 사이 웹페이지·시리얼로 손으로 바꾼 것은 다음 변화 때까지 그대로 둔다.
 * 본체와 5번 연속 연결이 안 되면 전체를 끈다(무장이 풀렸는지 모르면 켜 두지 않는다).
 *
 * 명령 (웹페이지, http://<IP>/cmd?c=명령, 또는 시리얼 115200)
 *   1 ~ 4                     해당 LED 토글
 *   L1 ON / L1 OFF / L1 T     1~4번 LED 켜기 / 끄기 / 토글
 *   L1 128                    밝기 0~255
 *   ALL ON / ALL OFF          전체
 *   MODE CHASE                1->2->3->4 순서로 흐르기
 *   MODE BLINK                전체 깜빡이기
 *   MODE KNIGHT               왕복 (1->4->1)
 *   MODE OFF                  패턴 정지
 *   SPEED 200                 패턴 속도(ms)
 *   STATUS                    현재 밝기 상태
 *   HUB                       본체 연동 상태
 *
 * 와이파이·본체 주소·키는 secrets.h 에 둔다(secrets.h.example 을 복사, 저장소에 올리지 않음).
 */
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include "secrets.h"

const uint8_t LED_PINS[4] = { D1, D2, D5, D6 };
uint8_t level[4] = { 0, 0, 0, 0 };      // 각 LED 밝기 0~255

enum Mode { M_NONE, M_CHASE, M_BLINK, M_KNIGHT };
Mode mode = M_NONE;
unsigned long patternMs = 200;
unsigned long lastStep = 0;
int step = 0;

ESP8266WebServer server(80);

// 본체 연동 상태
const unsigned long POLL_MS = 1000;
const int MAX_FAILS = 5;
unsigned long lastPoll = 0;
int hubFails = 0;
int hubLight = -1;                // -1 모름, 0 꺼짐, 1 켜짐
unsigned long welcomeUntil = 0;   // 켜질 때 흐르기를 보여 주는 끝 시각

// ---------------- LED ----------------
void setLevel(int i, int v) {
  level[i] = constrain(v, 0, 255);
  analogWrite(LED_PINS[i], level[i]);
}

void setAll(int v) {
  for (int i = 0; i < 4; i++) setLevel(i, v);
}

String status() {
  String s = "";
  for (int i = 0; i < 4; i++) {
    s += "L" + String(i + 1) + "=" + String(level[i]);
    if (i < 3) s += " ";
  }
  return s;
}

// 패턴 한 단계씩 (loop에서 non-blocking으로 호출)
void runPattern() {
  if (mode == M_NONE) return;
  if (millis() - lastStep < patternMs) return;
  lastStep = millis();

  switch (mode) {
    case M_CHASE:
      for (int i = 0; i < 4; i++) setLevel(i, i == step ? 255 : 0);
      step = (step + 1) % 4;
      break;
    case M_BLINK:
      setAll(step ? 255 : 0);
      step = !step;
      break;
    case M_KNIGHT: {
      // 0,1,2,3,2,1 반복
      int pos = step < 4 ? step : 6 - step;
      for (int i = 0; i < 4; i++) setLevel(i, i == pos ? 255 : 0);
      step = (step + 1) % 6;
      break;
    }
    default: break;
  }
}

// ---------------- 본체 연동 ----------------
void applyHubLight(int on) {
  if (on == hubLight) return;
  hubLight = on;
  if (on) {                       // 들어오면 한 바퀴 흐른 뒤 전체 켜기
    mode = M_CHASE; step = 0; lastStep = 0; patternMs = 150;
    welcomeUntil = millis() + 1200;
  } else {
    mode = M_NONE; welcomeUntil = 0;
    setAll(0);
  }
}

void finishWelcome() {
  if (welcomeUntil && (long)(millis() - welcomeUntil) >= 0) {
    welcomeUntil = 0;
    mode = M_NONE;
    setAll(255);
  }
}

void pollHub() {
  if (millis() - lastPoll < POLL_MS) return;
  lastPoll = millis();
  if (WiFi.status() != WL_CONNECTED) { hubFails++; }
  else {
    WiFiClient client;
    HTTPClient http;
    http.setTimeout(800);
    if (http.begin(client, String(HUB_URL) + "/model/state")) {
      http.addHeader("X-API-Key", HUB_KEY);
      int code = http.GET();
      if (code == 200) {
        String body = http.getString();
        hubFails = 0;
        applyHubLight(body.indexOf("\"light\":true") >= 0 ? 1 : 0);
      } else {
        hubFails++;
      }
      http.end();
    } else {
      hubFails++;
    }
  }
  if (hubFails >= MAX_FAILS && hubLight != 0) applyHubLight(0);
}

// ---------------- 명령 처리 ----------------
String handleCommand(String cmd) {
  cmd.trim();
  cmd.toUpperCase();
    // 숫자 하나(1~4)만 보내면 해당 LED 토글
  if (cmd.length() == 1 && cmd[0] >= '1' && cmd[0] <= '4') {
    int i = cmd[0] - '1';
    mode = M_NONE;
    setLevel(i, level[i] ? 0 : 255);
    return status();
  }
  if (cmd == "STATUS") return status();
  if (cmd == "HUB") return "light=" + String(hubLight) + " fails=" + String(hubFails);

  if (cmd == "ALL ON")  { mode = M_NONE; setAll(255); return status(); }
  if (cmd == "ALL OFF") { mode = M_NONE; setAll(0);   return status(); }

  // L1 ON / L1 OFF / L1 T / L1 128
  if (cmd.length() >= 4 && cmd[0] == 'L' && cmd[1] >= '1' && cmd[1] <= '4' && cmd[2] == ' ') {
    int i = cmd[1] - '1';
    String arg = cmd.substring(3);
    arg.trim();
    mode = M_NONE;                                 // 수동 조작하면 패턴 정지
    if (arg == "ON")       setLevel(i, 255);
    else if (arg == "OFF") setLevel(i, 0);
    else if (arg == "T")   setLevel(i, level[i] ? 0 : 255);
    else if (isDigit(arg[0])) setLevel(i, arg.toInt());
    else return "Usage: L1 ON|OFF|T|0~255";
    return status();
  }

  if (cmd.startsWith("MODE ")) {
    String m = cmd.substring(5);
    m.trim();
    step = 0;
    lastStep = 0;
    if (m == "CHASE")       mode = M_CHASE;
    else if (m == "BLINK")  mode = M_BLINK;
    else if (m == "KNIGHT") mode = M_KNIGHT;
    else if (m == "OFF")  { mode = M_NONE; setAll(0); }
    else return "Unknown mode: " + m;
    return "MODE " + m;
  }

  if (cmd.startsWith("SPEED ")) {
    patternMs = constrain(cmd.substring(6).toInt(), 30, 2000);
    return "SPEED " + String(patternMs) + "ms";
  }

  return "Unknown: " + cmd;
}

// ---------------- 웹페이지 ----------------
const char PAGE[] PROGMEM = R"HTML(
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LED x4</title>
<style>
body{font-family:sans-serif;max-width:420px;margin:20px auto;padding:0 12px}
.row{display:flex;align-items:center;gap:10px;margin:10px 0}
.dot{width:28px;height:28px;border-radius:50%;background:#ccc;border:1px solid #888}
button{padding:10px;font-size:15px;min-width:64px}
input[type=range]{flex:1}
#log{background:#eee;padding:8px;min-height:24px;margin-top:12px}
</style></head><body>
<h3>LED 4개 제어</h3>
<div id="leds"></div>
<p><button onclick="s('ALL ON')">전체 ON</button> <button onclick="s('ALL OFF')">전체 OFF</button></p>
<p>패턴
<button onclick="s('MODE CHASE')">흐르기</button>
<button onclick="s('MODE KNIGHT')">왕복</button>
<button onclick="s('MODE BLINK')">깜빡</button>
<button onclick="s('MODE OFF')">정지</button></p>
<div class="row">속도 <input type="range" min="30" max="1000" value="200"
  oninput="sv.textContent=this.value" onchange="s('SPEED '+this.value)"><span id="sv">200</span>ms</div>
<div id="log"></div>
<script>
const box=document.getElementById('leds');
for(let i=1;i<=4;i++){
  box.insertAdjacentHTML('beforeend',
  `<div class="row"><div class="dot" id="d${i}"></div><b>LED${i}</b>
   <button onclick="s('L${i} T')">토글</button>
   <input type="range" min="0" max="255" value="0" id="r${i}" onchange="s('L${i} '+this.value)"></div>`);
}
function show(t){
  log.textContent=t;
  const m=t.match(/L(\d)=(\d+)/g); if(!m) return;
  m.forEach(x=>{const [i,v]=x.slice(1).split('=');
    document.getElementById('d'+i).style.background=v>0?`rgba(255,170,0,${0.25+v/340})`:'#ccc';
    document.getElementById('r'+i).value=v;});
}
function s(c){fetch('/cmd?c='+encodeURIComponent(c)).then(r=>r.text()).then(show)}
setInterval(()=>s('STATUS'),700);
s('STATUS');
</script></body></html>
)HTML";

void setup() {
  Serial.begin(115200);
  analogWriteRange(255);
  analogWriteFreq(1000);
  for (int i = 0; i < 4; i++) {
    pinMode(LED_PINS[i], OUTPUT);
    setLevel(i, 0);
  }

  // 부팅 테스트: 1~4번 순서대로 잠깐 켜기 (배선 확인용)
  for (int i = 0; i < 4; i++) { setLevel(i, 255); delay(200); setLevel(i, 0); }

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(300); Serial.print('.'); }
  Serial.println();
  Serial.print("IP: "); Serial.println(WiFi.localIP());

  server.on("/", []() { server.send_P(200, "text/html", PAGE); });
  server.on("/cmd", []() {
    server.send(200, "text/plain; charset=utf-8", handleCommand(server.arg("c")));
  });
  server.begin();
}

void loop() {
  server.handleClient();
  pollHub();
  runPattern();
  finishWelcome();

  if (Serial.available()) {
    Serial.println(handleCommand(Serial.readStringUntil('\n')));
  }
}
