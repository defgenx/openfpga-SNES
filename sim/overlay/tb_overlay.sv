// msu_overlay behind the real scanline_filler, with SNES-like NTSC timing
// (341 dots x 262 lines, 256x224 active). Checks the squares land where expected.
`timescale 1ns / 1ps
module tb_overlay;
  reg clk = 0;
  always #93 clk = ~clk;

  integer dot = 0, line = 0;
  wire hblank = dot >= 256;
  wire vblank = line >= 224;
  wire hsync = dot >= 280 && dot < 300;
  wire vsync_in = line >= 240 && line < 243;
  always @(posedge clk) begin
    dot <= dot == 340 ? 0 : dot + 1;
    if (dot == 340) line <= line == 261 ? 0 : line + 1;
  end

  wire hs, vs, de_out;
  wire [23:0] rgb_out;
  scanline_filler #(
      .SNAP_COUNT (1),
      .SNAP_POINTS('{224}),  // core_top uses 2 points; this simulator rejects that form
      .HSYNC_DELAY(1)
  ) filler (
      .clk(clk),
      .hsync_in(hsync),
      .vsync_in(vsync_in),
      .vblank_in(vblank),
      .hblank_in(hblank),
      .rgb_in(24'h123456),
      .hsync(hs),
      .vsync(vs),
      .de(de_out),
      .rgb(rgb_out),
      .snap_index(),
      .snap_point()
  );

  wire on;
  wire [23:0] orgb;
  msu_overlay ov (
      .clk(clk),
      .de(de_out),
      .vsync(vs),
      .probe_status(4'd4),
      .tstate(4'd0),
      .seen_busy(1'b0),
      .seen_ok(1'b1),
      .on(on),
      .rgb(orgb)
  );

  // core_top's output stage
  reg de = 0;
  reg [23:0] rgb = 0;
  always @(posedge clk) begin
    de <= 0;
    if (de_out) begin
      de  <= 1;
      rgb <= on ? orgb : rgb_out;
    end
  end

  // Measure the red square in output coordinates
  integer ox = 0, oy = 0, frames = 0, red = 0, green = 0, minx = 999, maxx = -1, miny = 999, maxy = -1;
  reg prev_de = 0;
  always @(posedge clk) begin
    prev_de <= de;
    if (de) begin
      if (rgb == 24'hFF0000) begin
        red = red + 1;
        if (ox < minx) minx = ox;
        if (ox > maxx) maxx = ox;
        if (oy < miny) miny = oy;
        if (oy > maxy) maxy = oy;
      end
      if (rgb == 24'h00FF00) green = green + 1;
      ox = ox + 1;
    end else ox = 0;
    if (prev_de && !de) oy = oy + 1;
    if (vs) begin
      if (frames == 3) begin
        $display("frame: red=%0d px x %0d..%0d y %0d..%0d, green=%0d px, lines=%0d", red, minx, maxx, miny, maxy,
                 green, oy);
        if (red == 32 * 32 && minx == 32 && maxx == 63 && green == 32 * 32) $display("PASS");
        else $display("FAIL");
        $finish;
      end
      frames = frames + 1;
      red = 0; green = 0; oy = 0; minx = 999; maxx = -1; miny = 999; maxy = -1;
    end
  end
endmodule
