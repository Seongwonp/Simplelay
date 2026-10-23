// Vendor first article: final left shell half, NOT the small fit coupon.
// Open this file and export STL. Keep simplelay_box.scad beside this file.
include <simplelay_box.scad>

// These overrides intentionally leave the legacy default model unchanged.
part = "none";
plug_room = 60;                // total clearance, previously 20 mm
left_clip_zs = [105, 190];     // lower boss moved +70 mm; right side unchanged
shell_horizontal_join = false;
vendor_part = "shell_left";   // shell_left | panel_clip | preview | panel_interference

module vendor_left() {
    intersection() {
        shell_solid();
        translate([-1, -1, -1]) cube([split_x + 1, depth + 2, H + 2]);
    }
}

if (vendor_part == "shell_left") vendor_left();
else if (vendor_part == "panel_clip") panel_clip();
else if (vendor_part == "preview") {
    color("ivory") vendor_left();
    color([0.2, 0.3, 0.4, 0.45]) face_frame()
        translate([panel_x0, wall, panel_up]) cube([panel_w, panel_t, panel_h]);
    for (c = clip_points()) if (c[2] == 0)
        color("orange") face_frame()
            translate([c[0] - clip_boss_d / 2, clip_top, c[1] + clip_w / 2])
                rotate([-90, 0, 0]) panel_clip();
}
else if (vendor_part == "panel_interference") {
    // Structural hardware only: the intended supporting ledge/side stops are excluded.
    intersection() {
        insert_obstacles();
        face_frame() translate([panel_x0, wall, panel_up]) cube([panel_w, panel_t, panel_h]);
    }
}

echo(str("VENDOR left shell: ", split_x, " x ", depth, " x ", H, " mm"));
echo(str("VENDOR total width: ", W, " mm; left clearance: ", plug_room, " mm"));
echo(str("VENDOR left lower/upper clip positions from panel bottom: ", left_clip_zs));
assert(plug_room == 60 && left_clip_zs == [105, 190] && !shell_horizontal_join,
       "Vendor revision parameters changed: verify fit before printing.");
