// SimpleLay 키오스크 하우징 2안 — 쐐기형 박스(3D 프린터 분할 출력용)
//
// 15.8형 터치 패널(354 x 225 x 4.7/9.6 mm, 사양표) + RPi5 + DHT22 온습도 센서를 상자 하나에 넣는다.
// 앞면은 20° 뒤로 기울고, RPi5는 뒤판 위쪽(배기는 위판 슬롯·흡기는 뒤판 아래).
// 센서는 앞 아래 턱 안의 칸 — 옆·뒤 칸막이와 위 뚜껑(sensor_lid, 선 홈 6 x 3)으로 본체 안 공기와 나누고,
// 앞 턱·바닥 슬롯으로 바깥 공기를 받는다(완전히 막힌 칸은 아니다: 선 홈으로 본체 안과 조금 통한다).
// 단위 mm. 축: X = 폭(왼쪽 → 오른쪽, 정면에서 볼 때), Y = 깊이(앞 0 → 뒤), Z = 높이(바닥 0 → 위).
//
// 2026-10-18: 하우징 검토(docs/하우징-검토-2026-10-18.md) 우선순위 1~11 중 실측 없이 할 수 있는 것을 반영했다.
//
// 출력: 아래 `part`를 바꿔 하나씩 렌더(F6) → STL 내보내기. 프린터 220 x 220 x 250 가정 — 조각별 크기는 맨 아래 echo.
//   "assembly"   전체 조립 모습(확인용, 출력하지 않음)    "cutaway"  왼쪽 일부를 잘라 안쪽을 본 모습(확인용)
//   "shell_LB"   몸통 왼쪽 아래   "shell_RB" 오른쪽 아래   "shell_LT" 왼쪽 위   "shell_RT" 오른쪽 위
//                (위 조각 LT·RT는 위판이 판에 닿게 뒤집힌 방향으로 나온다 — 서포트 줄이기)
//   "back_LB"    뒤판 왼쪽 아래   "back_RB"  오른쪽 아래   "back_LT"  왼쪽 위   "back_RT"  오른쪽 위(RPi5 — 정비 문)
//   "sensor_lid" 센서 칸 뚜껑(1개)
//   "panel_clip" 패널 누름 L자 고리(4개, 경사면 안쪽 고리 받침에 M3)
//   "vesa_plate" VESA 75 x 75 누름판(선택 — panel_hold = "vesa", 상자에 잇는 방법은 실측 뒤 정함)
//   "splice"     옛 평판 보강판(seam = "splice"일 때만 쓴다)
//   "fit_test"   맞춤 시험 조각(앞판 왼쪽 아래 모서리)
//   "none"       아무것도 그리지 않음(간섭 확인 파일에서 include할 때)
//
// **치수 상태:** 패널 외형·화면 영역·VESA 75 x 75는 사양표 값. '⚠ 실측 필요' 표시가 붙은 값은 추측이다.
// 실측 뒤 아래 숫자만 고치면 된다. 조립 순서·실측 목록은 housing/README.md.

part = "assembly";

// ── 패널(사양표) ─────────────────────────────────────────────
panel_w      = 354;      // 외형 가로
panel_h      = 225;      // 외형 세로
panel_t      = 9.6;      // 가장 두꺼운 곳(아래)
screen_w     = 349.632;  // 표시 영역
screen_h     = 196.668;
screen_up    = 10;       // ⚠ 실측 필요 — 패널 아래 끝 → 표시 영역 아래 끝. 지금 값은 추측(틀리면 키오스크 맨 아래 줄이 가려진다)
panel_fit    = 0.5;      // 좌우 멈춤 턱 사이 = 패널 폭 + 이 값(한쪽 0.25)

// ── 화면 창(#2) ─────────────────────────────────────────────
win_margin   = 0.5;      // 창 = 표시 영역 + 사방 이 값(좌우는 표시 영역이 가운데라고 가정 — 테두리 실측 필요)
win_chamfer  = 2;        // 창 바깥 모서리 45° 모따기(가장자리 터치 쉽게), wall보다 작게

// ── 상자 ────────────────────────────────────────────────────
wall         = 3;        // 벽 두께
tilt         = 20;       // 앞면 기울기(수직에서 뒤로, 도)
lip_h        = 30;       // 앞 아래 턱 높이(센서 칸)
plug_room    = 20;       // ⚠ 실측 필요 — 패널 왼쪽 옆면 ㄱ자 플러그 여유(세 가닥 플러그 몸체 길이 + 5)
side_room    = 16;       // 패널 오른쪽 여유(10/18: 8 → 16, 오른쪽 나사 받침을 패널 폭 밖으로)
depth        = 170;      // 바닥 깊이
face_len     = panel_h + 20;              // 경사면 길이(패널 + 위아래 여유)
H            = lip_h + face_len * cos(tilt);    // 전체 높이 ≈ 260
top_front_y  = face_len * sin(tilt);            // 위판 앞 모서리 깊이 ≈ 84
W            = wall + plug_room + panel_w + side_room + wall;   // 전체 폭 ≈ 396
panel_x0     = wall + plug_room;           // 패널 왼쪽 끝 X
panel_up     = 10;                         // 경사면 시작에서 패널 아래까지

// ── 분할 ────────────────────────────────────────────────────
split_x      = W / 2;
split_z      = H / 2;

// ── 패널 좌우 멈춤 턱(#1) ───────────────────────────────────
stop_w       = 3;        // 턱 폭(X)
stop_len     = 8;        // 턱 길이(경사면 따라)
stop_taper   = 10;       // 위쪽으로 벽에 붙이는 경사(뒤집어 출력하는 위 조각의 오버행 줄이기)
stop_zs      = [0, panel_h - stop_len];    // 패널 아래 끝에서 턱 위치. 왼쪽 턱은 포트 위치를 피해야 한다(⚠ 실측 필요)

// ── 패널 받침 턱·받침살(#10) ────────────────────────────────
ledge_d      = panel_t + 3;                // 받침 턱 깊이(벽에 1 mm 묻힘 포함)
ledge_x0     = panel_x0 - panel_fit / 2 - stop_w;            // 멈춤 턱까지 받친다
ledge_x1     = panel_x0 + panel_w + panel_fit / 2 + stop_w;
gusset_t     = 2.4;      // 45° 받침살 두께
gusset_pitch = 30;       // 받침살 간격

// ── 나사·인서트(#11) ────────────────────────────────────────
insert_d     = 4.0;      // ⚠ 실측 필요 — M3 열 인서트 구멍. 산 인서트 데이터시트의 권장 구멍을 따른다
insert_len   = 6;        // 인서트 구멍 깊이(고리 받침) — 인서트 길이 + 0.5 이상
boss_d       = 10;       // 나사 받침 지름(10 이상 — 인서트 둘레 살)
boss_len     = 10;       // 뒤판 나사 받침 길이(Y)
bolt_d       = 3.4;      // M3 통과 구멍

// ── 뒤판 나사 받침(#3·#4) ───────────────────────────────────
boss_in      = 10;       // 바깥면에서 받침 중심까지
boss_from_split = 20;    // 분할선에서 받침 중심까지(가장자리 15 = 20 − boss_d/2)

// ── 뒤판 ────────────────────────────────────────────────────
back_gap     = 0.3;      // 뒤판은 몸통 뒤 테두리 안쪽에 끼운다(사방 간격)
in_n = 14;  in_w = 5;  in_h = 50;  in_pitch = 10;   // 아래 흡기 슬롯(분할선 양쪽 7개씩)

// ── RPi5(뒤판 위쪽 안쪽에 세로로) ────────────────────────────
rpi_hole_dx  = 58;   rpi_hole_dz = 49;   rpi_hole_d = 2.7;   // M2.5
rpi_center   = [W * 0.62, H * 0.62];     // 뒤판에서 RPi5 중심(X, Z) — 구멍 4개 모두 RT 조각

// ── 센서 칸(앞 아래 턱 안, #5) ───────────────────────────────
// 다른 안(모델에 넣지 않음): 센서를 상자 밖 — 앞 턱 아래나 왼쪽 옆면 바깥 주머니 — 에 두면 상자 열을 덜 받는다.
sensor_x0    = 30;   sensor_w = 60;   sensor_d = 55;
lid_t        = 2;        // 뚜껑 두께
lid_gap      = 0.3;      // 뚜껑 둘레 간격
lid_sup      = 1.5;      // 뚜껑 받침 턱(칸 안쪽 둘레)
lid_z0       = lip_h - 1 - lid_t;          // 뚜껑 아랫면 높이(윗면이 받침 턱 밑보다 1 mm 낮게)
wire_slot    = [6, 3];   // 뚜껑 뒤 가장자리 선 홈(폭 X, 깊이 Y)
sv_w = 4;  sv_pitch = 7;  sv_side = 4;  sv_z0 = 6;  sv_h = lip_h - 12;   // 앞 턱 통풍 슬롯
bay_floor_vents = true;  // 칸 바닥 슬롯(고무발로 바닥이 떠 있어야 공기가 든다)

// ── 위판 배기(#6) ───────────────────────────────────────────
ex_w         = 6;    ex_pitch = 12;   ex_len = 45;
ex_split_gap = 10;       // 세로 분할선 ±10 mm는 막아 둔다(이음 살·덧살)
ex_y0        = top_front_y + 8;           // 패널 뒤 더운 공기가 모이는 위판 앞 모서리부터

// ── 이음(#7) ────────────────────────────────────────────────
seam         = "rib";    // "rib" 덧살 + M3 볼트·너트(기본, 풀 수 있음) | "splice" 옛 평판 보강판 접착
seam_rib_h   = 6;        // 덧살 높이(벽에서 안쪽으로)
seam_rib_t   = 4;        // 덧살 두께(분할면 한쪽)
seam_spot_d  = 6.4;      // 옆벽 덧살 볼트 머리·너트 자리(모따기 쪽 평면 내기)
seam_floor_ys = [25, 85, 145];                         // 바닥 덧살 볼트 Y
top_rib_y0   = top_front_y + 12;                       // 위판 덧살 시작(패널 위 끝과 간격)
seam_top_ys  = [top_front_y + 30, depth - wall - 15];  // 위판 덧살 볼트 Y
side_rib_y0  = (split_z + seam_rib_t + seam_rib_h - lip_h) * tan(tilt) + wall / cos(tilt) + 25;  // 패널·플러그 뒤로 비켜서
side_rib_ys  = [side_rib_y0 + 10, depth - wall - 15];  // 옆벽 덧살 볼트 Y

// ── 패널 누름(#8) ───────────────────────────────────────────
panel_hold   = "clip";   // "clip" 고리 받침 + L자 고리(기본) | "vesa" VESA 누름판(구멍 위치·나사·상자 고정 실측 뒤)
clip_foam    = 1;        // 고리와 패널 뒤 사이 폼 두께
clip_boss_d  = 10;
clip_taper   = 25;       // 고리 받침을 벽에 붙이는 경사 길이(오버행 줄이기)
clip_zs      = [35, panel_h - 35];  // 패널 아래 끝에서 고리 위치. 왼쪽은 포트·OSD 버튼을 피해야 한다(⚠ 실측 필요)
clip_w       = 10;   clip_t = 3;   clip_overlap = 8;   // 패널 위에 걸치는 길이
clip_step    = 0;        // ⚠ 실측 필요 — 고리 끝 누름 턱 높이(패널 뒤가 4.7 mm 쪽이면 두께 차를 여기·폼으로 맞춤)
vesa         = 75;       // VESA 75 x 75(사양표)
vesa_plate_w = 95;   vesa_plate_t = 4;
vesa_hole_d  = 4.5;      // ⚠ 실측 필요 — VESA 나사 규격(M4 가정), 구멍 위치(패널 가운데 가정)

// ── 고무발(#9) ──────────────────────────────────────────────
foot_d       = 12;       // ⚠ 실측 필요 — 산 고무발 지름
foot_depth   = 1;
foot_in      = 14;       // 바깥 모서리에서 고무발 중심까지

// ── 프린터 ──────────────────────────────────────────────────
printer      = [220, 220, 250];

$fn = 40;

// ===== 파생 값 =====
win_x0  = panel_x0 + (panel_w - screen_w) / 2 - win_margin;
win_z0  = panel_up + screen_up - win_margin;
win_w   = screen_w + 2 * win_margin;
win_h   = screen_h + 2 * win_margin;

bay_x0  = sensor_x0 - wall;
bay_x1  = sensor_x0 + sensor_w + wall;
sv_n    = floor((sensor_w - 2 * sv_side - sv_w) / sv_pitch) + 1;
sv_xs   = [for (i = [0 : sv_n - 1]) sensor_x0 + sv_side + i * sv_pitch];

ex_xs   = [for (x = [panel_x0 : ex_pitch : panel_x0 + panel_w - ex_w])
           if (x + ex_w <= split_x - ex_split_gap || x >= split_x + ex_split_gap) x];

in_xs   = concat([for (k = [1 : in_n / 2]) split_x - k * in_pitch - in_w / 2],
                 [for (k = [1 : in_n / 2]) split_x + k * in_pitch - in_w / 2]);

back_x0 = wall + back_gap;   back_x1 = W - wall - back_gap;
back_z0 = wall + back_gap;   back_z1 = H - wall - back_gap;

// 받침 턱 아랫면의 뒤 모서리(lg)와 벽 쪽 끝(lf), 세계 좌표 (Y, Z)
lg_y = (wall - 1 + ledge_d) * cos(tilt) + (panel_up - 4) * sin(tilt);
lg_z = lip_h - (wall - 1 + ledge_d) * sin(tilt) + (panel_up - 4) * cos(tilt);
lf_y = (wall - 1) * cos(tilt) + (panel_up - 4) * sin(tilt);
lf_z = lip_h - (wall - 1) * sin(tilt) + (panel_up - 4) * cos(tilt);

gusset_xs = concat([ledge_x0, bay_x0, bay_x1 - gusset_t, ledge_x1 - gusset_t],
                   [for (x = [panel_x0 + 2 : gusset_pitch : panel_x0 + panel_w - 2 - gusset_t])
                    if ((x + gusset_t < bay_x0 - 1 || x > bay_x1 + 1)
                        && (x + gusset_t < split_x - seam_rib_t - 2 || x > split_x + seam_rib_t + 2)) x]);

clip_top = wall + panel_t + clip_foam;     // 고리 받침 윗면(경사면 좌표 y')
clip_xL  = panel_x0 - panel_fit / 2 - 1 - clip_boss_d / 2;
clip_xR  = panel_x0 + panel_w + panel_fit / 2 + 1 + clip_boss_d / 2;
clip_len = clip_boss_d + 1 + panel_fit / 2 + clip_overlap;

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
        // 화면 창(#2): 표시 영역 + 사방 win_margin, 바깥 모서리 45° 모따기
        face_frame() {
            translate([win_x0, -10, win_z0]) cube([win_w, 20, win_h]);
            hull() {
                translate([win_x0 - win_chamfer - 1, -1, win_z0 - win_chamfer - 1])
                    cube([win_w + 2 * (win_chamfer + 1), 0.01, win_h + 2 * (win_chamfer + 1)]);
                translate([win_x0, win_chamfer, win_z0]) cube([win_w, 0.01, win_h]);
            }
        }
        // 위판 배기 슬롯(#6): 위판 앞 모서리부터, 패널 폭 전체, 세로 분할선 ±10 mm는 비움
        for (x = ex_xs) translate([x, ex_y0, H - wall - 1]) cube([ex_w, ex_len, wall + 2]);
        // 센서 칸 통풍(#5): 앞 턱 + 바닥
        for (x = sv_xs) translate([x, -1, sv_z0]) cube([sv_w, wall + 2, sv_h]);
        if (bay_floor_vents)
            for (x = sv_xs) translate([x, wall + 6, -1]) cube([sv_w, sensor_d - 12, wall + 2]);
        // 오른쪽 옆 버튼 구멍(패널 오른쪽 옆면 OSD 버튼 — ⚠ 위치 실측 필요)
        face_frame() translate([W - wall - 1, 2, panel_up + panel_h * 0.25]) cube([wall + 2, 14, 60]);
        // 고무발 자리(#9)
        for (fx = [foot_in, W - foot_in], fy = [foot_in, depth - foot_in])
            translate([fx, fy, -1]) cylinder(d = foot_d, h = foot_depth + 1);
    }
    // 패널 받침 턱(경사면 안쪽, 패널 아래 모서리를 받친다) — 멈춤 턱 밑까지
    face_frame() translate([ledge_x0, wall - 1, panel_up - 4]) cube([ledge_x1 - ledge_x0, ledge_d, 4]);  // 벽에 1 mm 묻힘
    // 받침 턱 아래 45° 받침살(#10) + 센서 칸 위는 받침 턱 밑을 칸 높이까지 채움
    for (x = gusset_xs) ledge_gusset(x);
    ledge_fill(bay_x0, bay_x1);
    // 패널 좌우 멈춤 턱(#1)
    for (s = [0, 1], zo = stop_zs) stop_ridge(s, zo);
    // 패널 누름 고리 받침(#8)
    for (c = clip_points()) clip_boss(c[0], c[1]);
    // 센서 칸
    sensor_bay();
    // 뒤판 나사 받침(M3 열 인서트) — 가까운 벽까지 이어 떨어지지 않게 한다
    for (p = boss_points()) boss(p);
    // 분할 이음 덧살(#7)
    if (seam == "rib") seam_ribs();
}

module ledge_gusset(x) {
    // 받침 턱 아래 뒤 모서리에서 45°로 앞 턱 안쪽 벽까지 내려가는 삼각 받침살
    translate([x, 0, 0]) rotate([90, 0, 90]) linear_extrude(gusset_t)
        polygon([[lg_y, lg_z], [wall - 0.5, lg_z - (lg_y - wall + 0.5)], [wall - 0.5, lip_h], [lf_y, lf_z]]);
}

module ledge_fill(x0, x1) {
    // 받침 턱 아래를 z = lip_h까지 채움(센서 칸 위 — 칸 뚜껑과 1 mm 간격)
    translate([x0, 0, 0]) rotate([90, 0, 90]) linear_extrude(x1 - x0)
        polygon([[lg_y, lip_h], [lg_y, max(lg_z, lip_h + 0.1)], [lf_y, lf_z], [wall - 0.5, lip_h]]);
}

module stop_ridge(s, zo) {
    // 경사면 안쪽, 패널 옆에 서는 멈춤 턱(폭 stop_w × 길이 stop_len × 패널 두께)
    x0 = s == 0 ? panel_x0 - panel_fit / 2 - stop_w : panel_x0 + panel_w + panel_fit / 2;
    face_frame() hull() {
        translate([x0, wall - 1, panel_up + zo]) cube([stop_w, panel_t + 1, stop_len]);
        translate([x0, wall - 1, panel_up + zo]) cube([stop_w, 1, stop_len + stop_taper]);
    }
}

function clip_points() = [for (s = [0, 1], co = clip_zs) [s == 0 ? clip_xL : clip_xR, panel_up + co, s]];

module clip_boss(x, zc) {
    // 경사면 안쪽에 선 고리 받침 — 윗면(y' = clip_top)에 L자 고리를 M3(열 인서트)로 조인다
    face_frame() difference() {
        hull() {
            translate([x, wall - 1, zc]) rotate([-90, 0, 0]) cylinder(d = clip_boss_d, h = clip_top - wall + 1);
            translate([x - clip_boss_d / 2, wall - 1, zc - clip_taper]) cube([clip_boss_d, 1, 2 * clip_taper]);
        }
        translate([x, clip_top - insert_len, zc]) rotate([-90, 0, 0]) cylinder(d = insert_d, h = insert_len + 1);
    }
}

module sensor_bay() {
    // 칸막이(옆·뒤)
    translate([sensor_x0 - wall, wall, wall]) cube([wall, sensor_d, lip_h - wall]);
    translate([sensor_x0 + sensor_w, wall, wall]) cube([wall, sensor_d, lip_h - wall]);
    translate([sensor_x0 - wall, wall + sensor_d, wall]) cube([sensor_w + 2 * wall, wall, lip_h - wall]);
    // 뚜껑 받침 턱(좌·우·앞, 뒤는 선 홈 아래를 비움)
    sz = lid_z0 - lid_sup;
    translate([sensor_x0, wall, sz]) cube([lid_sup, sensor_d, lid_sup]);
    translate([sensor_x0 + sensor_w - lid_sup, wall, sz]) cube([lid_sup, sensor_d, lid_sup]);
    translate([sensor_x0, wall, sz]) cube([sensor_w, lid_sup, lid_sup]);
    for (s = [0, 1])
        translate([s == 0 ? sensor_x0 : sensor_x0 + sensor_w / 2 + wire_slot[0] / 2 + 1, wall + sensor_d - lid_sup, sz])
            cube([sensor_w / 2 - wire_slot[0] / 2 - 1, lid_sup, lid_sup]);
}

module sensor_lid() {
    // 센서 칸 뚜껑 — 앞쪽을 받침 턱 밑으로 밀어 넣고 뒤쪽을 내려 받침 턱에 얹는다. 뒤 가장자리 가운데 선 홈.
    lw = sensor_w - 2 * lid_gap;   ld = sensor_d - 2 * lid_gap;
    difference() {
        cube([lw, ld, lid_t]);
        translate([(lw - wire_slot[0]) / 2, ld - wire_slot[1], -1]) cube([wire_slot[0], wire_slot[1] + 1, lid_t + 2]);
    }
}

// 뒤판 나사 받침: 분할선에서 boss_from_split, 가운데·위 줄은 패널 폭 밖(패널 세워 넣는 길), 뒤판 조각마다 3개.
function boss_points() = [
    // LB: 왼쪽 아래 모서리, 아래 줄(분할선 왼쪽), 왼쪽 줄(분할선 아래)
    [boss_in, boss_in], [split_x - boss_from_split, boss_in], [boss_in, split_z - boss_from_split],
    // RB
    [W - boss_in, boss_in], [split_x + boss_from_split, boss_in], [W - boss_in, split_z - boss_from_split],
    // LT: 왼쪽 줄 3개
    [boss_in, split_z + boss_from_split], [boss_in, (split_z + boss_from_split + H - boss_in) / 2], [boss_in, H - boss_in],
    // RT: 오른쪽 줄 3개(RPi5 구멍도 이 조각)
    [W - boss_in, split_z + boss_from_split], [W - boss_in, (split_z + boss_from_split + H - boss_in) / 2], [W - boss_in, H - boss_in]
];

module boss(p) {
    x = p[0];  z = p[1];
    y0 = depth - wall - boss_len;
    // 가까운 벽(바닥·위판·옆벽) 안에 묻힌 얇은 판까지 hull로 잇는다
    difference() {
        hull() {
            translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(d = boss_d, h = boss_len);
            if (z < 20)            translate([x - boss_d / 2, y0, wall / 2]) cube([boss_d, boss_len, 1]);
            else if (z > H - 20)   translate([x - boss_d / 2, y0, H - wall / 2 - 1]) cube([boss_d, boss_len, 1]);
            else if (x < W / 2)    translate([wall / 2, y0, z - boss_d / 2]) cube([1, boss_len, boss_d]);
            else                   translate([W - wall / 2 - 1, y0, z - boss_d / 2]) cube([1, boss_len, boss_d]);
        }
        translate([x, y0 - 1, z]) rotate([-90, 0, 0]) cylinder(d = insert_d, h = boss_len + 2);
    }
}

module seam_ribs() {
    // 분할면을 따라 안쪽에 덧살(분할면 양쪽 seam_rib_t씩) — M3 볼트 + 너트로 덧살끼리 조인다(접착 없이 풀 수 있음).
    // 경사면 띠(창 위·아래·좌·우)는 패널이 바로 붙어 덧살 자리가 없다 → 접착.
    t = seam_rib_t;  h = seam_rib_h;
    difference() {
        union() {
            // 세로 분할(x = split_x): 바닥 · 앞 턱 · 위판
            translate([split_x - t, wall - 0.5, wall - 0.5]) cube([2 * t, depth - 2 * wall + 0.5, h + 0.5]);
            translate([split_x - t, wall - 0.5, wall - 0.5]) cube([2 * t, h + 0.5, lip_h - 4 - wall + 0.5]);
            translate([split_x - t, top_rib_y0, H - wall - h]) cube([2 * t, depth - wall - top_rib_y0, h + 0.5]);
        }
        for (y = seam_floor_ys)
            translate([split_x - t - 1, y, wall + h / 2]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = 2 * t + 2);
        translate([split_x - t - 1, wall + h / 2, (wall + lip_h - 4) / 2]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = 2 * t + 2);
        for (y = seam_top_ys)
            translate([split_x - t - 1, y, H - wall - h / 2]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = 2 * t + 2);
    }
    // 가로 분할(z = split_z): 왼쪽 · 오른쪽 옆벽
    for (sx = [0, 1]) side_rib(sx);
}

module side_rib(sx) {
    // 옆벽 안쪽 가로 덧살 — 위아래를 45° 모따기(어느 방향으로 출력해도 서포트 없이), 볼트 자리는 평면으로 깎음
    t = seam_rib_t;  h = seam_rib_h;
    xw  = sx == 0 ? wall : W - wall;      // 옆벽 안쪽 면
    dir = sx == 0 ? 1 : -1;               // 안쪽 방향
    bx  = xw + dir * (h / 2 + 0.5);       // 볼트 X
    rib_len = depth - wall - side_rib_y0;
    difference() {
        translate([0, depth - wall, 0]) rotate([90, 0, 0]) linear_extrude(rib_len)
            polygon([[xw - dir * 0.5, split_z - t - h - 0.5], [xw + dir * h, split_z - t],
                     [xw + dir * h, split_z + t], [xw - dir * 0.5, split_z + t + h + 0.5]]);
        for (y = side_rib_ys) {
            translate([bx, y, split_z - t - h - 2]) cylinder(d = bolt_d, h = 2 * (t + h) + 4);
            translate([bx, y, split_z - t - h - 2]) cylinder(d = seam_spot_d, h = h + 2);
            translate([bx, y, split_z + t]) cylinder(d = seam_spot_d, h = h + 2);
        }
    }
}

module back_plate() {
    // 몸통 뒤 테두리(벽 3 mm) 안쪽에 끼워 나사 받침 끝면(y = depth − wall)에 닿는다
    difference() {
        translate([back_x0, depth - wall, back_z0]) cube([back_x1 - back_x0, wall, back_z1 - back_z0]);
        // 아래 흡기 슬롯(분할선 양쪽)
        for (x = in_xs) translate([x, depth - wall - 1, 20]) cube([in_w, wall + 2, in_h]);
        // 전원 입구(Type-C 선 두 가닥)
        translate([W - 60, depth - wall - 1, 12]) cube([36, wall + 2, 14]);
        // RPi5 고정 구멍 M2.5
        for (dx = [-1, 1], dz = [-1, 1])
            translate([rpi_center[0] + dx * rpi_hole_dx / 2, depth - wall - 1, rpi_center[1] + dz * rpi_hole_dz / 2])
                rotate([-90, 0, 0]) cylinder(d = rpi_hole_d, h = wall + 2);
        // 나사 구멍 M3
        for (p = boss_points())
            translate([p[0], depth - wall - 1, p[1]]) rotate([-90, 0, 0]) cylinder(d = bolt_d, h = wall + 2);
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
    // (seam = "splice"일 때만) 이음매 안쪽에 대는 평판 보강판 — 접착. 몸통에 나사 받을 곳이 없다(검토 #7).
    difference() {
        cube([40, 20, 3]);
        for (x = [8, 32]) translate([x, 10, -1]) cylinder(d = 3.2, h = 5);
    }
}

module panel_clip() {
    // L자 누름 고리 — 한쪽 끝을 고리 받침 윗면에 M3로 조이고(받침과 L자), 다른 끝 clip_overlap이 패널 뒤 가장자리를 폼 너머로 누른다.
    // 판에 눕혀 출력. clip_step > 0이면 끝에 누름 턱(달 때 패널 쪽으로).
    difference() {
        union() {
            cube([clip_len, clip_w, clip_t]);
            if (clip_step > 0) translate([clip_len - clip_overlap, 0, clip_t]) cube([clip_overlap, clip_w, clip_step]);
        }
        translate([clip_boss_d / 2, clip_w / 2, -1]) cylinder(d = bolt_d, h = clip_t + clip_step + 2);
    }
}

module vesa_plate() {
    // (선택) 패널 뒤 VESA 75 x 75 구멍에 조이는 누름판. 상자에 잇는 방법은 VESA 구멍·나사 실측 뒤 정한다.
    difference() {
        cube([vesa_plate_w, vesa_plate_w, vesa_plate_t]);
        for (dx = [-1, 1], dy = [-1, 1])
            translate([vesa_plate_w / 2 + dx * vesa / 2, vesa_plate_w / 2 + dy * vesa / 2, -1])
                cylinder(d = vesa_hole_d, h = vesa_plate_t + 2);
    }
}

module insert_obstacles() {
    // 패널 넣는 길 간섭 확인용(README) — 뒤판 받침 · 이음 덧살 · 고리 받침
    for (p = boss_points()) boss(p);
    if (seam == "rib") seam_ribs();
    for (c = clip_points()) clip_boss(c[0], c[1]);
}

module show_parts() {
    // 확인용 부품(출력하지 않음)
    color("dimgray", 0.9) face_frame() translate([panel_x0, wall, panel_up]) cube([panel_w, panel_t, panel_h]);
    // RPi5(85 x 56 보드 + 쿨러 ≈20, 스탠드오프 미포함)
    color("tomato", 0.7) translate([rpi_center[0] - 28, depth - wall - 22, rpi_center[1] - 42.5]) cube([56, 20, 85]);
    // DHT22(눕혀서 — 칸 높이가 뚜껑 때문에 낮아짐, 격자 면이 앞 슬롯 쪽)
    color("seagreen") translate([sensor_x0 + 17, wall + 6, wall + 2]) cube([25, 8, 15]);
    color("khaki") translate([sensor_x0 + lid_gap, wall + lid_gap, lid_z0]) sensor_lid();
    if (panel_hold == "clip")
        color("orange") for (c = clip_points())
            face_frame() translate([c[2] == 0 ? c[0] - clip_boss_d / 2 : c[0] + clip_boss_d / 2 - clip_len, clip_top, c[1] - clip_w / 2])
                cube([clip_len, clip_t, clip_w]);
    else if (panel_hold == "vesa")
        color("orange") face_frame()
            translate([panel_x0 + panel_w / 2 - vesa_plate_w / 2, wall + panel_t, panel_up + panel_h / 2 - vesa_plate_w / 2])
                cube([vesa_plate_w, vesa_plate_t, vesa_plate_w]);
}

// 출력 방향: 아래 조각은 바닥을 판에, 위 조각은 뒤집어 위판을 판에, 뒤판은 눕혀서.
module lay_back(ix, iz) {
    translate([0, 0, wall]) rotate([90, 0, 0]) translate([0, -depth, 0]) quad(ix, iz) back_plate();
}

if (part == "assembly") {
    color("gainsboro") shell_solid();
    color("silver", 0.8) back_plate();
    show_parts();
}
else if (part == "cutaway") {
    // 확인용 — 왼쪽 일부를 잘라 안쪽(센서 칸·뚜껑·패널 턱·나사 받침·RPi5 자리)을 본다
    intersection() {
        union() {
            shell_solid();
            back_plate();
            show_parts();
        }
        translate([sensor_x0 + 25, -10, -10]) cube([W, depth + 20, H + 20]);
    }
}
else if (part == "fit_test") {
    // 맞춤 시험 조각(약 1시간) — 앞판 왼쪽 아래 모서리: 화면 창 모서리·받침 턱·멈춤 턱·고리 받침·센서 칸·플러그 여유.
    // 실제 패널을 대 보고 창 위치·걸침·받침 턱을 확인한 뒤 큰 조각을 뽑는다.
    intersection() {
        shell_solid();
        translate([-1, -1, -1]) cube([panel_x0 + 45, 70, lip_h + 70]);
    }
}
else if (part == "shell_LB") quad(0, 0) shell_solid();
else if (part == "shell_RB") quad(1, 0) shell_solid();
else if (part == "shell_LT") translate([0, depth, H]) rotate([180, 0, 0]) quad(0, 1) shell_solid();   // 뒤집어 위판이 판에
else if (part == "shell_RT") translate([0, depth, H]) rotate([180, 0, 0]) quad(1, 1) shell_solid();
else if (part == "back_LB") lay_back(0, 0);
else if (part == "back_RB") lay_back(1, 0);
else if (part == "back_LT") lay_back(0, 1);
else if (part == "back_RT") lay_back(1, 1);
else if (part == "sensor_lid") sensor_lid();
else if (part == "panel_clip") panel_clip();
else if (part == "vesa_plate") vesa_plate();
else if (part == "splice") splice();

// ===== 확인 echo =====
function fits(s) = s[2] <= printer[2]
    && ((s[0] <= printer[0] && s[1] <= printer[1]) || (s[1] <= printer[0] && s[0] <= printer[1]));
function in_piece(p, ix, iz) = (p[0] < split_x ? 0 : 1) == ix && (p[1] < split_z ? 0 : 1) == iz;
function boss_count(ix, iz) = len([for (p = boss_points()) if (in_piece(p, ix, iz)) 1]);

part_sizes = [   // 조각별 바깥 크기(상한)
    ["shell_LB",  [split_x, depth, split_z]],
    ["shell_RB",  [W - split_x, depth, split_z]],
    ["shell_LT",  [split_x, depth, H - split_z]],
    ["shell_RT",  [W - split_x, depth, H - split_z]],
    ["back_LB",   [split_x - back_x0, split_z - back_z0, wall]],
    ["back_RB",   [back_x1 - split_x, split_z - back_z0, wall]],
    ["back_LT",   [split_x - back_x0, back_z1 - split_z, wall]],
    ["back_RT",   [back_x1 - split_x, back_z1 - split_z, wall]],
    ["sensor_lid", [sensor_w - 2 * lid_gap, sensor_d - 2 * lid_gap, lid_t]],
    ["panel_clip", [clip_len, clip_w, clip_t + clip_step]],
    ["vesa_plate", [vesa_plate_w, vesa_plate_w, vesa_plate_t]],
    ["fit_test",  [panel_x0 + 44, 69, lip_h + 69]],
    ["splice",    [40, 20, 3]]
];
boss_split_min = min([for (p = boss_points()) min(abs(p[0] - split_x), abs(p[1] - split_z))]) - boss_d / 2;
boss_panel_min = min([for (p = boss_points()) if (p[1] > lip_h)
                      max(panel_x0 - (p[0] + boss_d / 2), (p[0] - boss_d / 2) - (panel_x0 + panel_w))]);
rpi_on_RT = rpi_center[0] - rpi_hole_dx / 2 - rpi_hole_d / 2 > split_x
         && rpi_center[1] - rpi_hole_dz / 2 - rpi_hole_d / 2 > split_z;

echo(str("전체 크기 W x D x H = ", W, " x ", depth, " x ", H, " mm"));
for (p = part_sizes)
    echo(str("조각 ", p[0], " ", p[1][0], " x ", p[1][1], " x ", p[1][2], " mm — ",
             fits(p[1]) ? "프린터 안" : "**프린터 초과**"));
echo(str("뒤판 나사 받침 개수 LB/RB/LT/RT = ", boss_count(0, 0), "/", boss_count(1, 0), "/",
         boss_count(0, 1), "/", boss_count(1, 1), " (각 3 이상)"));
echo(str("받침 가장자리 ~ 분할선 최소 ", boss_split_min, " mm (15 이상), 가운데·위 줄 받침 ~ 패널 옆 최소 ",
         boss_panel_min, " mm (0보다 커야 패널 폭 밖)"));
echo(str("RPi5 구멍 4개 RT 조각: ", rpi_on_RT));
echo(str("배기 ", len(ex_xs), "개 = ", len(ex_xs) * ex_w * ex_len, " mm² (5000 이상), 흡기 ",
         len(in_xs), "개 = ", len(in_xs) * in_w * in_h, " mm², 센서 칸 앞 ", sv_n * sv_w * sv_h,
         " + 바닥 ", bay_floor_vents ? sv_n * sv_w * (sensor_d - 12) : 0, " mm²"));
echo(str("화면 창 ", win_w, " x ", win_h, " (경사면 z′ ", win_z0, " ~ ", win_z0 + win_h,
         "), screen_up = ", screen_up, " ⚠ 실측 필요"));
