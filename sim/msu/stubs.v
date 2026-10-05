// Behavioral stand-ins for vendor/VHDL primitives so the MSU path runs under Icarus.

module dcfifo #(
    parameter lpm_width = 8,
    parameter lpm_widthu = 2,
    parameter lpm_numwords = 4,
    parameter lpm_showahead = "OFF",
    parameter intended_device_family = "",
    parameter lpm_type = "",
    parameter overflow_checking = "",
    parameter underflow_checking = "",
    parameter use_eab = "",
    parameter rdsync_delaypipe = 0,
    parameter wrsync_delaypipe = 0,
    parameter clocks_are_synchronized = "",
    parameter read_aclr_synch = "",
    parameter write_aclr_synch = ""
) (
    input wire aclr,
    input wire [lpm_width-1:0] data,
    input wire rdclk,
    input wire rdreq,
    input wire wrclk,
    input wire wrreq,
    output wire [lpm_width-1:0] q,
    output wire rdempty,
    output wire wrfull,
    output wire [lpm_widthu-1:0] wrusedw,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire rdfull,
    output wire wrempty,
    output wire [1:0] eccstatus
);
  reg [lpm_width-1:0] mem[0:lpm_numwords-1];
  integer wp = 0;
  integer rp = 0;
  wire [31:0] used = wp - rp;

  assign rdempty = used == 0;
  assign wrfull = used >= lpm_numwords;
  assign wrusedw = used[lpm_widthu-1:0];
  assign rdusedw = used[lpm_widthu-1:0];
  assign rdfull = wrfull;
  assign wrempty = rdempty;
  assign eccstatus = 0;
  reg [lpm_width-1:0] q_reg;

  always @(posedge wrclk or posedge aclr) begin
    if (aclr) wp <= 0;
    else if (wrreq && !wrfull) begin
      mem[wp%lpm_numwords] <= data;
      wp <= wp + 1;
    end
  end

  always @(posedge rdclk or posedge aclr) begin
    if (aclr) rp <= 0;
    else if (rdreq && !rdempty) begin
      q_reg <= mem[rp%lpm_numwords];
      rp <= rp + 1;
    end
  end

  assign q = lpm_showahead == "ON" ? mem[rp%lpm_numwords] : q_reg;
endmodule

module CEGen (
    input wire CLK,
    input wire RST_N,
    input wire [31:0] IN_CLK,
    input wire [31:0] OUT_CLK,
    output reg CE
);
  // Sample rate is scaled by the testbench so a track plays in reasonable sim time
  parameter SPEEDUP = 8;
  reg [63:0] sum = 0;
  always @(negedge CLK or negedge RST_N) begin
    if (!RST_N) begin
      sum <= 0;
      CE  <= 0;
    end else begin
      CE <= 0;
      if (sum + OUT_CLK * SPEEDUP >= IN_CLK) begin
        sum <= sum + OUT_CLK * SPEEDUP - IN_CLK;
        CE  <= 1;
      end else sum <= sum + OUT_CLK * SPEEDUP;
    end
  end
endmodule

module mf_datatable (
    input wire [9:0] address_a,
    input wire [9:0] address_b,
    input wire clock_a,
    input wire clock_b,
    input wire [31:0] data_a,
    input wire [31:0] data_b,
    input wire wren_a,
    input wire wren_b,
    output reg [31:0] q_a,
    output reg [31:0] q_b
);
  reg [31:0] mem[0:1023];
  reg [9:0] ra, rb;
  integer i;
  initial for (i = 0; i < 1024; i = i + 1) mem[i] = 0;
  always @(posedge clock_a) begin
    ra <= address_a;
    if (wren_a) mem[address_a] <= data_a;
    q_a <= mem[ra];
  end
  always @(posedge clock_b) begin
    rb <= address_b;
    if (wren_b) mem[address_b] <= data_b;
    q_b <= mem[rb];
  end
endmodule
