// MSU-1 diagnostic overlay for test builds: two 32x32 squares near the top-left corner, see
// docs/MSU-1.md for the colours. Square 1 (x 32-63) is the boot probe result, square 2
// (x 72-103) the APF target command handshake.
module msu_overlay (
    input wire clk,
    input wire de,
    input wire vsync,  // scanline_filler's one-cycle pulse
    input wire [2:0] probe_status,
    input wire [3:0] tstate,
    input wire seen_busy,
    input wire seen_ok,
    output wire on,
    output wire [23:0] rgb
);
  reg de_prev = 0;
  reg vs_prev = 0;
  always @(posedge clk) begin
    de_prev <= de;
    vs_prev <= vsync;
  end

  reg [8:0] msu_overlay_x = 0;
  reg [8:0] msu_overlay_y = 0;

  always @(posedge clk) begin
    if (de) msu_overlay_x <= msu_overlay_x + 1'd1;
    else msu_overlay_x <= 0;
    if (~de && de_prev) msu_overlay_y <= msu_overlay_y + 1'd1;
    if (vsync && ~vs_prev) msu_overlay_y <= 0;
  end

  wire msu_overlay_row = msu_overlay_y >= 32 && msu_overlay_y < 64;
  wire msu_square1 = msu_overlay_row && msu_overlay_x >= 32 && msu_overlay_x < 64;
  wire msu_square2 = msu_overlay_row && msu_overlay_x >= 72 && msu_overlay_x < 104;
  assign on = msu_square1 || msu_square2;

  reg [23:0] msu_probe_rgb;
  always @(*) begin
    case (probe_status)
      3'd0: msu_probe_rgb = 24'h404040;  // no probe yet
      3'd1: msu_probe_rgb = 24'h00FF00;  // MSU-1 enabled
      3'd2: msu_probe_rgb = 24'h0000FF;  // Get Filename failed
      3'd3: msu_probe_rgb = 24'hFFFFFF;  // ROM path unusable (no terminator, too long)
      3'd4: msu_probe_rgb = 24'hFF0000;  // <rom>.msu not found
      3'd5: msu_probe_rgb = 24'hFFFF00;  // Open File failed otherwise
      3'd6: msu_probe_rgb = 24'hFF00FF;  // APF did not answer
      default: msu_probe_rgb = 24'hA0A0A0;  // probe in progress
    endcase
  end

  reg [23:0] msu_handshake_rgb;
  always @(*) begin
    if (tstate == 4'd14) msu_handshake_rgb = 24'hFF00FF;  // waiting for Ready to Run ack
    else if (tstate == 4'd15 && !seen_busy) msu_handshake_rgb = 24'hFF0000;  // posted, not picked up
    else if (tstate == 4'd15) msu_handshake_rgb = 24'hFFFF00;  // busy, not finished
    else if (seen_ok) msu_handshake_rgb = 24'h00FF00;  // idle, last command answered
    else msu_handshake_rgb = 24'h0000FF;  // idle, no command answered yet
  end

  assign rgb = msu_square1 ? msu_probe_rgb : msu_handshake_rgb;
endmodule
