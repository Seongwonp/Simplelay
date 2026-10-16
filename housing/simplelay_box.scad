// SimpleLay 키오스크 하우징 2안 — 쐐기형 박스(3D 프린터 분할 출력용)
//
// 15.8형 터치 패널(354 x 225 x 4.7/9.6 mm, 사양표) + RPi5 + DHT22 온습도 센서를 상자 하나에 넣는다.
// 앞면은 20° 뒤로 기울고, RPi5는 뒤판 위쪽(배기는 위판 슬롯·흡기는 뒤판 아래), 센서는 앞 아래 턱 안의 막힌 칸.
// 단위 mm. 축: X = 폭(왼쪽 → 오른쪽, 정면에서 볼 때), Y = 깊이(앞 0 → 뒤), Z = 높이(바닥 0 → 위).
//
// 출력: 아래 `part`를 바꿔 하나씩 렌더(F6) → STL 내보내기. 프린터 220 x 220 x 250 가정 — 모든 조각이 그 안에 들어간다.
//   "assembly"   전체 조립 모습(확인용, 출력하지 않음)
//   "shell_LB"   몸통 왼쪽 아래   "shell_RB" 오른쪽 아래   "shell_LT" 왼쪽 위   "shell_RT" 오른쪽 위
//   "back_LB"    뒤판 왼쪽 아래   "back_RB"  오른쪽 아래   "back_LT"  왼쪽 위   "back_RT"  오른쪽 위
//   "splice"     이음 보강판(여러 개 출력, 조각 이음매 안쪽에 접착·나사)
//   "panel_clip" 패널 누름 고리(8개 출력)
//
// **치수 상태:** 패널 외형·화면 영역은 사양표 값. 기울기·여유·단자 위치·버튼 위치·센서 크기는 1차안(추측/실측 필요).
// 실측 뒤 아래 숫자만 고치면 된다. 조립 순서는 housing/README.md.

part = "assembly";

// ── 패널(사양표) ─────────────────────────────────────────────
panel_w      = 354;      // 외형 가로
panel_h      = 225;      // 외형 세로
panel_t      = 9.6;      // 가장 두꺼운 곳(아래)
screen_w     = 349.632;  // 화면 영역
screen_h     = 196.668;
screen_up    = 10;       // 패널 아래 테두리에서 화면 아래까지(추측/실측 필요)

// ── 상자 ────────────────────────────────────────────────────
wall         = 3;        // 벽 두께
tilt         = 20;       // 앞면 기울기(수직에서 뒤로, 도)
lip_h        = 30;       // 앞 아래 턱 높이(센서 칸)
plug_room    = 20;       // 패널 왼쪽 옆면 ㄱ자 플러그 여유(추측/실측 필요)
side_room    = 8;        // 패널 오른쪽 여유(버튼 쪽)
depth        = 170;      // 바닥 깊이
face_len     = panel_h + 20;              // 경사면 길이(패널 + 위아래 여유)
H            = lip_h + face_len * cos(tilt);    // 전체 높이 ≈ 260
top_front_y  = face_len * sin(tilt);            // 위판 앞 모서리 깊이 ≈ 84
W            = wall + plug_room + panel_w + side_room + wall;   // 전체 폭 ≈ 388
panel_x0     = wall + plug_room;           // 패널 왼쪽 끝 X
panel_up     = 10;                         // 경사면 시작에서 패널 아래까지

// ── 분할 ────────────────────────────────────────────────────
split_x      = W / 2;
split_z      = H / 2;

// ── RPi5(뒤판 위쪽 안쪽에 세로로) ────────────────────────────
rpi_hole_dx  = 58;   rpi_hole_dz = 49;   rpi_hole_d = 2.7;   // M2.5
rpi_center   = [W * 0.62, H * 0.62];     // 뒤판에서 RPi5 중심(X, Z)

// ── 센서 칸(앞 아래 턱 안) ───────────────────────────────────
sensor_x0    = 30;   sensor_w = 60;   sensor_d = 55;

$fn = 40;

// ===== 기본 형상 =====
module profile2d(off = 0) {
    // 옆에서 본 단면(Y, Z). off > 0이면 안쪽으로 줄인 윤곽.
    offset(delta = -off)
        polygon([[0, 0], [depth, 0], [depth, H], [top_front_y, H], [0, lip_h]]);
}

module face_frame() {
    // 경사면 좌표계: x는 폭, z는 경사면을 따라 위로, y는 면에 수직(+ 안쪽).
    translate([0, 0, lip_h]) rotate([-tilt, 0, 0]) children();
}

module shell_solid() {
    difference() {
        rotate([90, 0, 90]) linear_extrude(W) profile2d();
        // 속 비우기(뒤는 뒤판으로 막으니 뚫어 둔다)
        translate([wall, 0, 0]) rotate([90, 0, 90]) linear_extrude(W - 2 * wall) profile2d(wall);
        translate([wall, depth - wall - 0.01, wall]) cube([W - 2 * wall, wall + 1, H - 2 * wall]);
        // 화면 창
        face_frame() translate([panel_x0 + (panel_w - screen_w) / 2, -10, panel_up + screen_up])
            cube([screen_w, 20, screen_h]);
        // 위판 배기 슬롯(뒤쪽 절반)
        for (i = [0 : 9]) translate([W * 0.35 + i * 12, top_front_y + 25, H - wall - 1]) cube([6, 45, wall + 2]);
        // 센서 칸 통풍 슬롯(앞 턱)
        for (i = [0 : 5]) translate([sensor_x0 + 6 + i * 9, -1, 8]) cube([4, wall + 2, lip_h - 16]);
        // 오른쪽 옆 버튼 구멍(패널 오른쪽 옆면 OSD 버튼 — 위치 추측/실측 필요)
        face_frame() translate([W - wall - 1, 2, panel_up + panel_h * 0.25]) cube([wall + 2, 14, 60]);
    }
    // 패널 받침 턱(경사면 안쪽, 패널 아래 모서리를 받친다)
    face_frame() translate([panel_x0, wall - 1, panel_up - 4]) cube([panel_w, panel_t + 3, 4]);  // 벽에 1 mm 묻힘
    // 센서 칸 칸막이(옆·뒤)
    translate([sensor_x0 - wall, wall, wall]) cube([wall, sensor_d, lip_h - wall]);
    translate([sensor_x0 + sensor_w, wall, wall]) cube([wall, sensor_d, lip_h - wall]);
    translate([sensor_x0 - wall, wall + sensor_d, wall]) cube([sensor_w + 2 * wall, wall, lip_h - wall]);
    // 뒤판 나사 받침(M3 열 인서트용 구멍 4.2) — 가까운 벽까지 기둥으로 이어 떨어지지 않게 한다
    for (p = boss_points()) boss(p);
}

function boss_points() = [[12, 12], [W - 12, 12], [12, H - 12], [W - 12, H - 12],
                          [split_x - 10, 12], [split_x + 10, H - 12], [12, split_z], [W - 12, split_z]];

module boss(p) {
    x = p[0];  z = p[1];
    y0 = depth - wall - 10;
    // 가까운 벽: 바닥(아래 줄)·위판(위 줄)·옆벽(가운데 줄)
    anchor = z < 20 ? [x, wall / 2] : z > H - 20 ? [x, H - wall / 2]
           : [x < W / 2 ? wall / 2 : W - wall / 2, z];
    difference() {
        hull() {
            translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(d = 9, h = 10);
            translate([anchor[0] - 3, y0, anchor[1] - 1]) cube([6, 10, 2]);
        }
        translate([x, y0 - 1, z]) rotate([-90, 0, 0]) cylinder(d = 4.2, h = 12);
    }
}

module back_plate() {
    difference() {
        translate([0, depth - wall, 0]) cube([W, wall, H]);
        // 아래 흡기 슬롯
        for (i = [0 : 13]) translate([W * 0.3 + i * 10, depth - wall - 1, 20]) cube([5, wall + 2, 50]);
        // 전원 입구(Type-C 선 두 가닥)
        translate([W - 60, depth - wall - 1, 12]) cube([36, wall + 2, 14]);
        // RPi5 고정 구멍 M2.5
        for (dx = [-1, 1], dz = [-1, 1])
            translate([rpi_center[0] + dx * rpi_hole_dx / 2, depth - wall - 1, rpi_center[1] + dz * rpi_hole_dz / 2])
                rotate([-90, 0, 0]) cylinder(d = rpi_hole_d, h = wall + 2);
        // 나사 구멍 M3
        for (p = boss_points())
            translate([p[0], depth - wall - 1, p[1]]) rotate([-90, 0, 0]) cylinder(d = 3.4, h = wall + 2);
    }
}

// ===== 분할 =====
module quad(ix, iz) {
    // ix: 0 왼쪽 / 1 오른쪽, iz: 0 아래 / 1 위
    intersection() {
        children();
        translate([ix == 0 ? -1 : split_x, -50, iz == 0 ? -1 : split_z])
            cube([ix == 0 ? split_x + 1 : W - split_x + 1, depth + 100, iz == 0 ? split_z + 1 : H - split_z + 1]);
    }
}

module splice() {
    // 이음매 안쪽에 대는 보강판 — 순간접착제 + 양쪽 M3 나사(자체 탭)
    difference() {
        cube([40, 20, 3]);
        for (x = [8, 32]) translate([x, 10, -1]) cylinder(d = 3.2, h = 5);
    }
}

module panel_clip() {
    // 패널 뒤를 눌러 주는 고리 — 경사면 안쪽에 접착, 패널 두께 9.6 + 여유
    difference() {
        cube([16, panel_t + 6, 8]);
        translate([-1, 3, 3]) cube([18, panel_t + 0.6, 6]);
    }
}

// 출력 방향: 몸통 조각은 바닥(또는 분할면)을 판에 대고, 뒤판은 눕혀서.
module lay_back(ix, iz) {
    translate([0, 0, 0]) rotate([90, 0, 0]) translate([0, -depth, 0]) quad(ix, iz) back_plate();
}

if (part == "assembly") {
    color("gainsboro") shell_solid();
    color("silver", 0.8) back_plate();
    // 패널(확인용)
    color("dimgray", 0.9) face_frame() translate([panel_x0, wall, panel_up]) cube([panel_w, panel_t, panel_h]);
    // RPi5(확인용, 85 x 56 보드 + 쿨러 ≈20)
    color("tomato", 0.7) translate([rpi_center[0] - 28, depth - wall - 22, rpi_center[1] - 42.5]) cube([56, 20, 85]);
    // DHT22(확인용)
    color("seagreen") translate([sensor_x0 + 22, wall + 15, wall + 2]) cube([15, 8, 25]);
}
else if (part == "cutaway") {
    // 확인용 — 왼쪽 절반을 잘라 안쪽(센서 칸·패널 턱·나사 받침·RPi5 자리)을 본다
    intersection() {
        union() {
            shell_solid();
            back_plate();
            face_frame() translate([panel_x0, wall, panel_up]) cube([panel_w, panel_t, panel_h]);
            translate([rpi_center[0] - 28, depth - wall - 22, rpi_center[1] - 42.5]) cube([56, 20, 85]);
            translate([sensor_x0 + 22, wall + 15, wall + 2]) cube([15, 8, 25]);
        }
        translate([sensor_x0 + 25, -10, -10]) cube([W, depth + 20, H + 20]);
    }
}
else if (part == "shell_LB") quad(0, 0) shell_solid();
else if (part == "shell_RB") quad(1, 0) shell_solid();
else if (part == "shell_LT") translate([0, 0, -split_z]) quad(0, 1) shell_solid();
else if (part == "shell_RT") translate([0, 0, -split_z]) quad(1, 1) shell_solid();
else if (part == "back_LB") lay_back(0, 0);
else if (part == "back_RB") lay_back(1, 0);
else if (part == "back_LT") lay_back(0, 1);
else if (part == "back_RT") lay_back(1, 1);
else if (part == "splice") splice();
else if (part == "panel_clip") panel_clip();

echo(str("전체 크기 W x D x H = ", W, " x ", depth, " x ", H, " mm, 조각 최대 ",
         split_x, " x ", depth, " x ", split_z));
