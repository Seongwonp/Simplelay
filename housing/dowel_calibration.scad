// Printed-fit calibration, not a replacement for production joinery.
// Use the existing 3.8 x 20 mm pin. Print flat, without scaling.
// Each cell has one vertical and one horizontal blind hole, depth 10.5.
// Hole diameters: 4.0, 4.1, 4.2, 4.3, 4.4 mm.
// Overall bounds: 176 x 18 x 16.6 mm. Front strip joins the five cells.
$fn = 64;
diameters = [4.0, 4.1, 4.2, 4.3, 4.4];
pitch = 38;

module cell(d) {
    difference() {
        cube([24, 18, 16]);
        translate([8, 9, 5.5]) cylinder(d=d, h=10.6);
        translate([13.5, 9, 8]) rotate([0, 90, 0]) cylinder(d=d, h=10.6);
    }
    translate([17, 3, 16]) linear_extrude(0.6)
        text(str(d), size=3, halign="center");
}

union() {
    cube([4 * pitch + 24, 2, 2]);
    for (i = [0:4]) translate([i * pitch, 0, 0]) cell(diameters[i]);
}
