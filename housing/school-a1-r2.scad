// R2 하우징 — 학교 메이커스페이스 FDM(Bambu Lab A1, 256 mm)용 위·아래 분할판.
// simplelay_box.scad를 같은 폴더에 둔다. `part`를 바꿔 하나씩 렌더(F6) → STL 내보내기.
//
// 업체용 R2(vendor-first-print-2026-10-23.scad)는 왼쪽 몸통을 위아래 통짜(218 × 170 × 260)로
// 만들어 A1 256 mm에 어느 방향으로도 들어가지 않는다. 여기서는 같은 R2 치수(폭 436, 왼쪽 포트
// 여유 60, 왼쪽 고리 받침 105·190)를 유지하고 몸통을 다시 위·아래로 나눈다.
//
// 가로 분할 높이: 기본(H/2 ≈ 130)은 R2에서 옮긴 왼쪽 아래 고리 받침(세계 z 약 110~161)을
// 가로지른다. 받침을 이음에 걸치면 나사 받침이 두 조각으로 갈라지므로, 분할을 오른쪽 아래
// 고리 받침(약 48~96)과 왼쪽 아래 고리 받침 사이로 내린다. 아래 echo·assert가 여유를 확인한다.
include <simplelay_box.scad>

part = "assembly";   // rpi5_case_tray · assembly_tray · fit_test · shell_LB·RB·LT·RT · back_LB·RB·LT·RT · sensor_lid · panel_clip · dowel_pin · assembly · cutaway

// ── R2 치수(업체용과 같다) ──
plug_room    = 60;
left_clip_zs = [105, 190];

// ── 위·아래 분할 ──
shell_horizontal_join = true;
split_z       = 103;
back_dowel_zs = [40, 85];   // 뒤판 LB–RB 핀은 아래 조각 안(분할 103 아래, 흡기 슬롯 사이 세로 분할선)

// ── RPi5 정품 케이스 받침(뒤판 RT 안쪽) ──
// 정품 케이스 외형 약 98.5 × 70.3 × 33(제조사 참고 치수 — 실측 필요). 케이스는 나사 구멍이 없어
// 받침 네 모서리 턱이 위치를 잡고, 찍찍이 끈(폭 20)이 케이스 위를 감아 뒤판 쪽으로 누른다.
// 받침은 뒤판 RT의 기존 M2.5 구멍 4개(58 × 49)에 M2.5 나사 + 너트로 붙인다(뒤판은 고치지 않는다).
case_l = 98.5;  case_w = 70.3;  case_h = 33;   // ⚠ 실측 필요
tray_fit   = 0.6;     // 케이스 둘레 한쪽 간격
tray_floor = 4;       // 바닥 두께(아랫면 끈 홈 1.5 + 너트 자리 2.2를 품는다)
tray_wall  = 2.5;     // 모서리 턱 두께
tray_lip   = 8;       // 모서리 턱 높이(포트는 케이스 바닥에서 이보다 높다고 가정 — 실측 필요)
tray_corner = 10;     // 모서리 턱 길이(긴 변의 USB-C·HDMI를 막지 않게 짧게)
strap_w = 23;  strap_slot = 3.5;  strap_edge = 2;   // 끈 구멍·아랫면 홈
nut_af = 5.0;  nut_t = 2.2;  // M2.5 육각 너트(맞변 5) — 산 너트 실측 필요
tray_shift_x = 8;     // 받침 중심을 RPi 구멍 중심에서 오른쪽으로(분할선 x = split_x 쪽 가장자리 여유)
tray_in_l = case_l + 2 * tray_fit;
tray_in_w = case_w + 2 * tray_fit;
tray_l = tray_in_l + 2 * tray_wall;
tray_w = tray_in_w + 2 * (strap_slot + 2 * strap_edge);   // 긴 변 바깥쪽에 끈 구멍 자리

module rpi5_case_tray() {
    // 받침 좌표: X 긴 변(케이스 길이), Y 짧은 변, Z 바닥에서 위(뒤판 → 상자 안쪽). 원점은 받침 가운데 바닥.
    difference() {
        union() {
            translate([-tray_l / 2, -tray_w / 2, 0]) cube([tray_l, tray_w, tray_floor]);
            for (sx = [-1, 1], sy = [-1, 1]) {
                cx = sx * (tray_in_l / 2 + tray_wall / 2);  cy = sy * (tray_in_w / 2 + tray_wall / 2);
                // 짧은 변 쪽 턱(Y 방향으로 tray_corner)과 긴 변 쪽 턱(X 방향으로 tray_corner)
                translate([cx - tray_wall / 2, sy > 0 ? tray_in_w / 2 - tray_corner : -tray_in_w / 2 - tray_wall, 0])
                    cube([tray_wall, tray_corner + tray_wall, tray_floor + tray_lip]);
                translate([sx > 0 ? tray_in_l / 2 - tray_corner : -tray_in_l / 2 - tray_wall, cy - tray_wall / 2, 0])
                    cube([tray_corner + tray_wall, tray_wall, tray_floor + tray_lip]);
            }
        }
        // M2.5 구멍 + 위쪽 너트 자리(케이스가 너트 위에 평평하게 앉는다)
        for (dx = [-1, 1], dz = [-1, 1]) {
            hx = dx * rpi_hole_dx / 2 - tray_shift_x;  hy = dz * rpi_hole_dz / 2;
            translate([hx, hy, -1]) cylinder(d = rpi_hole_d, h = tray_floor + 2);
            translate([hx, hy, tray_floor - nut_t]) cylinder(d = nut_af / cos(30), h = nut_t + 1, $fn = 6);
        }
        // 끈 구멍(긴 변 바깥쪽 두 줄) + 아랫면 홈(뒤판과 받침 사이로 끈이 지나간다)
        for (sx = [-1, 1]) {
            x0 = sx * case_l / 4 - strap_w / 2;
            for (sy = [-1, 1])
                translate([x0, sy > 0 ? tray_in_w / 2 + strap_edge : -tray_in_w / 2 - strap_edge - strap_slot, -1])
                    cube([strap_w, strap_slot, tray_floor + 2]);
            translate([x0, -tray_w / 2 - 1, -1]) cube([strap_w, tray_w + 2, 1.5 + 1]);
        }
    }
}

// 세계 좌표에 놓기: 받침 바닥이 뒤판 RT 안쪽 면(y = depth − wall)에 붙는다.
module rpi5_case_tray_placed() {
    translate([rpi_center[0] + tray_shift_x, depth - wall, rpi_center[1]])
        rotate([90, 0, 0]) rpi5_case_tray();
}

if (part == "rpi5_case_tray") rpi5_case_tray();
else if (part == "assembly_tray") {
    color("gainsboro") shell_solid();
    color("silver", 0.8) back_plate();
    color("orange") rpi5_case_tray_placed();
    color([0.2, 0.2, 0.2, 0.5]) translate([rpi_center[0] + tray_shift_x - case_l / 2, depth - wall - tray_floor - case_h,
                                            rpi_center[1] - case_w / 2]) cube([case_l, case_h, case_w]);
}

tray_x0 = rpi_center[0] + tray_shift_x - tray_l / 2;   tray_x1 = tray_x0 + tray_l;
tray_z0 = rpi_center[1] - tray_w / 2;                  tray_z1 = tray_z0 + tray_w;
tray_rt_gap = min(tray_x0 - (split_x + back_gap), (W - boss_in - boss_d / 2) - tray_x1,
                  tray_z0 - (split_z + back_gap), (back_z1) - tray_z1);
echo(str("RPi5 받침 ", tray_l, " × ", tray_w, " × ", tray_floor + tray_lip, " mm, 뒤판 RT 안 가장자리·나사 받침까지 최소 ", tray_rt_gap, " mm"));
assert(tray_rt_gap >= 3, "RPi5 받침이 뒤판 RT 가장자리·나사 받침에 너무 가깝다");

// ── 고리 받침이 차지하는 세계 Z 범위 확인 ──
// 받침은 경사면 좌표 z′ = panel_up + co를 중심으로 ±clip_taper, 면에서 y′ = wall − 1 ~ clip_top.
function boss_z_lo(co) = lip_h + (panel_up + co - clip_taper) * cos(tilt) - clip_top * sin(tilt);
function boss_z_hi(co) = lip_h + (panel_up + co + clip_taper) * cos(tilt) - (wall - 1) * sin(tilt);
clip_cos   = concat(left_clip_zs, clip_zs);
clip_gap   = min([for (co = clip_cos)
                  max(boss_z_lo(co) - split_z, split_z - boss_z_hi(co))]);
back_dowel_gap = split_z - (max(back_dowel_zs) + dowel_pad_l / 2);

echo(str("SCHOOL R2: 분할 z = ", split_z, ", 아래 ", split_z, " / 위 ", H - split_z, " mm"));
for (co = clip_cos)
    echo(str("  고리 받침 z′ ", panel_up + co, " → 세계 z ", boss_z_lo(co), " ~ ", boss_z_hi(co)));
echo(str("  고리 받침 ~ 분할면 최소 여유 ", clip_gap, " mm (3 이상)"));
echo(str("  뒤판 세로 이음 핀 덩어리 ~ 분할면 ", back_dowel_gap, " mm (3 이상)"));

assert(plug_room == 60 && left_clip_zs == [105, 190], "R2 치수가 바뀌었다 — 맞춤을 다시 확인할 것");
assert(clip_gap >= 3, "고리 받침이 가로 분할면에 걸친다 — split_z를 옮길 것");
assert(back_dowel_gap >= 3, "뒤판 세로 이음 핀이 가로 분할면에 걸친다");
assert(rpi_on_RT, "RPi5 구멍이 RT 조각 밖으로 나갔다");
assert(boss_split_min >= 15, "뒤판 나사 받침이 분할선에 너무 가깝다");
for (p = part_sizes) if (search([p[0]], ["shell_LB", "shell_RB", "shell_LT", "shell_RT",
                                        "back_LB", "back_RB", "back_LT", "back_RT"])[0] != [])
    assert(fits_in(p[1], printer_a1), str(p[0], "이 A1 256 mm를 넘는다"));
