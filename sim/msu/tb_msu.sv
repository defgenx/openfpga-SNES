// End-to-end MSU-1 path: a mock APF answering target commands through the real
// core_bridge_cmd, msu_apf, data_loader x2, msu_host, msu_sdram_store with an SNI
// model, and the upstream MSU.sv / msu_audio.v driven like a game would.
//
//   make -C sim/msu            (both bridge endiannesses, with and without MSU files)
`timescale 1ns / 1ps

module tb_msu;
  parameter LITTLE = 1;
  parameter HAVE_MSU = 1;
  // APF writes the filename struct in the opposite byte order to file data
  parameter STRUCT_SWAP = 0;
  // .msu larger than the (scaled-down) ring: streamed instead of copied at boot
  parameter STREAM = 0;
  // Super Road Blaster's access pattern with the hardware's chunk and lead sizes, music
  // playing at its real rate, and APF costs: a fixed latency per read plus a penalty when the
  // slot changes (APF drops its cluster-chain cache then; see docs/MSU-1.md)
  parameter SRB = 0;
  // ALttP randomizer (z3randomizer msu.asm) audio pack: empty .msu, pack detection, a 64-track
  // fallback scan, resume, fades
  parameter Z3R = 0;
  // MSU-1 video player: one seek, then VIDEO_KB read in each vertical blank at 60Hz with music.
  // A SNES moves ~6KB to VRAM per vblank, so players read a few KB per frame
  parameter VIDEO = 0;
  parameter VIDEO_KB = 6;
  parameter CMD_US = 300;
  parameter OPEN_US = 5000;  // APF Open File, unknown on hardware
  parameter SWITCH_US = 3000;
  localparam REAL = SRB || Z3R || VIDEO;  // charge APF costs and play music at its real rate
  localparam SEEK_BUDGET_US = 30000;  // the game polls MSU_STATUS $2000 times, ~34ms
  localparam RING_BITS = SRB || VIDEO ? 17 : 13;

  // ROM path chosen to exercise dots in directory names and in the file name
  localparam string ROM_PATH = "/Assets/snes/common/msu.packs/Game.v1.sfc";
  localparam string BASE = "/Assets/snes/common/msu.packs/Game.v1";

  localparam integer MSU_SIZE = Z3R ? 0 : VIDEO ? 700000 : SRB ? 300000 : STREAM ? 40000 : 3001;
  localparam integer T2_SAMPLES = 3000;  // tracks under 2KB hit an upstream msu_audio quirk (docs/MSU-1.md)
  localparam integer T34_SAMPLES = 3000;
  localparam integer T34_LOOP = 500;
  localparam integer T1_SAMPLES = 700;  // 2 full sectors + a partial one
  localparam integer T12_SAMPLES = 900;  // upstream drops a partial sector right after sector 0
  localparam integer T12_LOOP = 300;

  ////////////////////////////////////////////////////////////////////////////
  // Clocks: 74.25MHz bridge, 21.477MHz SNES, 4x SNES for SDRAM

  reg clk_74a = 0;
  reg clk_sys = 0;
  reg clk_mem = 0;
  always #6.734 clk_74a = ~clk_74a;
  initial begin
    #3;
    forever begin
      clk_mem = 1;
      clk_sys = 1;
      #5.82 clk_mem = 0;
      #5.82 clk_mem = 1;
      #5.82 clk_mem = 0;
      clk_sys = 0;
      #5.82 clk_mem = 1;
      #5.82 clk_mem = 0;
      #5.82 clk_mem = 1;
      #5.82 clk_mem = 0;
      #5.82;
    end
  end

  ////////////////////////////////////////////////////////////////////////////
  // Mock file system

  function automatic integer file_id(input string path);
    if (!HAVE_MSU) return 0;
    if (path == ROM_PATH) return 9;
    if (path == {BASE, ".msu"}) return 1;
    if (path == {BASE, "-1.pcm"}) return 2;
    if (path == {BASE, "-12.pcm"}) return 3;
    if (Z3R && path == {BASE, "-2.pcm"}) return 4;
    if (Z3R && path == {BASE, "-34.pcm"}) return 5;
    return 0;
  endfunction

  function automatic integer file_size(input integer id);
    case (id)
      1: return MSU_SIZE;
      2: return 8 + 4 * T1_SAMPLES;
      3: return 8 + 4 * T12_SAMPLES;
      4: return 8 + 4 * T2_SAMPLES;
      5: return 8 + 4 * T34_SAMPLES;
      9: return 32'h80000;
      default: return 0;
    endcase
  endfunction

  function automatic [7:0] file_byte(input integer id, input integer off);
    integer loop;
    loop = id == 3 ? T12_LOOP : id == 5 ? T34_LOOP : 0;
    if (id >= 2 && id <= 5 && off < 8) begin
      case (off)
        0: return "M";
        1: return "S";
        2: return "U";
        3: return "1";
        default: return loop >> (8 * (off - 4));
      endcase
    end
    return (off * 7 + id * 31 + (off >> 8) + (off >> 3)) & 8'hFF;
  endfunction

  function automatic [31:0] bswap(input [31:0] v);
    return {v[7:0], v[15:8], v[23:16], v[31:24]};
  endfunction

  // Raw bridge word holding file bytes b0..b3, matching data_loader's unpacking
  function automatic [31:0] pack(input [7:0] b0, input [7:0] b1, input [7:0] b2, input [7:0] b3);
    return LITTLE ? {b3, b2, b1, b0} : {b0, b1, b2, b3};
  endfunction

  localparam STRUCT_LITTLE = LITTLE ^ STRUCT_SWAP;
  function automatic [31:0] pack_struct(input [7:0] b0, input [7:0] b1, input [7:0] b2, input [7:0] b3);
    return STRUCT_LITTLE ? {b3, b2, b1, b0} : {b0, b1, b2, b3};
  endfunction

  ////////////////////////////////////////////////////////////////////////////
  // Bridge and core_bridge_cmd

  reg [31:0] bridge_addr = 0;
  reg bridge_rd = 0;
  reg bridge_wr = 0;
  reg [31:0] bridge_wr_data = 0;
  wire [31:0] cmd_rd_data;
  wire [31:0] scratch_rd_data;
  wire [31:0] bridge_rd_data = bridge_addr[31:28] == 4'h3 ? scratch_rd_data : cmd_rd_data;

  wire target_read, target_getfile, target_openfile;
  wire target_done;
  wire [2:0] target_err;
  wire [15:0] target_id;
  wire [31:0] target_offset, target_baddr, target_length;
  wire dt_active;
  wire [9:0] dt_addr;
  wire [31:0] datatable_q;

  core_bridge_cmd icb (
      .clk(clk_74a),
      .reset_n(),
      .bridge_endian_little(LITTLE[0]),
      .bridge_addr(bridge_addr),
      .bridge_rd(bridge_rd),
      .bridge_rd_data(cmd_rd_data),
      .bridge_wr(bridge_wr),
      .bridge_wr_data(bridge_wr_data),
      .status_boot_done(1'b1),
      .status_setup_done(1'b1),
      .status_running(1'b1),
      .dataslot_requestread_ack(1'b1),
      .dataslot_requestread_ok(1'b1),
      .dataslot_requestwrite_ack(1'b1),
      .dataslot_requestwrite_ok(1'b1),
      .savestate_supported(1'b0),
      .savestate_addr(32'b0),
      .savestate_size(32'b0),
      .savestate_maxloadsize(32'b0),
      .savestate_start_ack(1'b0),
      .savestate_start_busy(1'b0),
      .savestate_start_ok(1'b0),
      .savestate_start_err(1'b0),
      .savestate_load_ack(1'b0),
      .savestate_load_busy(1'b0),
      .savestate_load_ok(1'b0),
      .savestate_load_err(1'b0),
      .target_dataslot_read(target_read),
      .target_dataslot_write(1'b0),
      .target_dataslot_getfile(target_getfile),
      .target_dataslot_openfile(target_openfile),
      .target_dataslot_ack(),
      .target_dataslot_done(target_done),
      .target_dataslot_err(target_err),
      .target_dataslot_id(target_id),
      .target_dataslot_slotoffset(target_offset),
      .target_dataslot_bridgeaddr(target_baddr),
      .target_dataslot_length(target_length),
      .target_buffer_param_struct(32'h3000_0000),
      .target_buffer_resp_struct(32'h3000_0000),
      .datatable_addr(dt_active ? dt_addr : 10'd0),
      .datatable_wren(1'b0),
      .datatable_data(32'b0),
      .datatable_q(datatable_q)
  );

  ////////////////////////////////////////////////////////////////////////////
  // DUT, clk_74a side

  reg ioctl_download = 0;
  wire msu_busy, msu_enable, msu_data_download, audio_download;
  wire [3:0] probe_status;
  wire track_req_toggle, track_resp_toggle, sector_req_toggle;
  wire [15:0] track_num;
  wire [31:0] track_size;
  wire [21:0] sector_num;

  wire stream_underrun;
  wire stream_mode, seek_req_t, seek_resp_t, pos_req_t, pos_ack_t;
  wire [31:0] seek_addr, pos_value;
  wire pos_seeking;

  msu_apf #(
      .QUIET_BITS(8),
      .TIMEOUT_BITS(26),
      .RING_BITS(RING_BITS),
      .DATA_MAX_SIZE(4096),
      .STREAM_CHUNK(SRB || VIDEO ? 8192 : 1024),
      .STREAM_LEAD(SRB || VIDEO ? 4096 : 1024),
      .STREAM_GUARD(SRB || VIDEO ? 8192 : 1024),
      .STREAM_AHEAD(VIDEO ? 49152 : SRB ? 16384 : 2048)
  ) dut_apf (
      .clk_74a(clk_74a),
      .ioctl_download(ioctl_download),
      .core_running(1'b1),
      .bridge_endian_little(LITTLE[0]),
      .bridge_addr(bridge_addr),
      .bridge_rd(bridge_rd),
      .bridge_wr(bridge_wr),
      .bridge_wr_data(bridge_wr_data),
      .scratch_rd_data(scratch_rd_data),
      .target_dataslot_read(target_read),
      .target_dataslot_getfile(target_getfile),
      .target_dataslot_openfile(target_openfile),
      .target_dataslot_done(target_done),
      .target_dataslot_err(target_err),
      .target_dataslot_id(target_id),
      .target_dataslot_slotoffset(target_offset),
      .target_dataslot_bridgeaddr(target_baddr),
      .target_dataslot_length(target_length),
      .dt_active(dt_active),
      .dt_addr(dt_addr),
      .dt_q(datatable_q),
      .msu_busy(msu_busy),
      .msu_enable(msu_enable),
      .msu_data_download(msu_data_download),
      .audio_download(audio_download),
      .probe_status(probe_status),
      .track_req_toggle(track_req_toggle),
      .track_num(track_num),
      .track_resp_toggle(track_resp_toggle),
      .track_size(track_size),
      .sector_req_toggle(sector_req_toggle),
      .sector_num(sector_num),
      .stream_mode(stream_mode),
      .stream_underrun(stream_underrun),
      .data_seek_req_toggle(seek_req_t),
      .data_seek_addr(seek_addr),
      .data_seek_resp_toggle(seek_resp_t),
      .pos_req_toggle(pos_req_t),
      .pos_ack_toggle(pos_ack_t),
      .pos_value(pos_value),
      .pos_seeking(pos_seeking),
      .copy_req_toggle(copy_req_t),
      .copy_region(copy_region),
      .seek_region(seek_region),
      .copy_base(copy_base),
      .copy_len(copy_len),
      .fill_done_toggle(fill_done_t),
      .copy_done_toggle(copy_done_t)
  );

  wire rx_valid;
  wire [27:0] rx_addr;
  wire [31:0] rx_data;

  msu_bridge_rx bridge_rx (
      .clk_74a(clk_74a),
      .bridge_endian_little(LITTLE[0]),
      .bridge_addr(bridge_addr),
      .bridge_wr(bridge_wr),
      .bridge_wr_data(bridge_wr_data),
      .clk_sys(clk_sys),
      .rx_valid(rx_valid),
      .rx_addr(rx_addr),
      .rx_data(rx_data)
  );

  // Same split as SNES.sv
  wire audio_wr;
  wire [15:0] audio_data;

  ////////////////////////////////////////////////////////////////////////////
  // DUT, clk_sys side

  wire msu_enable_s, msu_busy_s, msu_data_download_s, audio_download_s;
  synch_3 #(
      .WIDTH(4)
  ) levels_s (
      {msu_enable, msu_busy, msu_data_download, audio_download},
      {msu_enable_s, msu_busy_s, msu_data_download_s, audio_download_s},
      clk_sys
  );

  wire reset = msu_busy_s;
  reg rst_n = 0;
  always @(posedge clk_sys) rst_n <= ~reset;

  reg [23:0] cpu_addr = 0;
  reg [7:0] cpu_dout = 0;
  reg cpu_rd_n = 1;
  reg cpu_wr_n = 1;
  reg cpu_ce = 0;
  wire [7:0] msu_dout;

  wire [15:0] m_track_num;
  wire m_track_request, m_track_mounting, m_track_missing;
  wire [7:0] m_volume;
  wire m_repeat, m_playing, m_stop, m_resume;
  wire [21:0] m_sector, m_resume_sector;
  wire [31:0] m_loop_index, m_resume_loop_index;
  wire [31:0] m_data_addr;
  wire [7:0] m_data;
  wire m_data_ack, m_data_seek, m_data_req;
  wire [31:0] m_audio_size;
  wire m_audio_ack, m_audio_req, m_audio_seek;

  MSU msu (
      .CLK(clk_sys),
      .RST_N(rst_n),
      .ENABLE(msu_enable_s),
      .RD_N(cpu_rd_n),
      .WR_N(cpu_wr_n),
      .SYSCLKF_CE(cpu_ce),
      .ADDR(cpu_addr),
      .DIN(cpu_dout),
      .DOUT(msu_dout),
      .MSU_SEL(),
      .track_num(m_track_num),
      .track_request(m_track_request),
      .track_mounting(m_track_mounting),
      .volume(m_volume),
      .status_track_missing(m_track_missing),
      .status_audio_repeat(m_repeat),
      .status_audio_playing(m_playing),
      .audio_stop(m_stop),
      .audio_resume(m_resume),
      .audio_sector(m_sector),
      .resume_sector(m_resume_sector),
      .audio_loop_index(m_loop_index),
      .resume_loop_index(m_resume_loop_index),
      .data_addr(m_data_addr),
      .data(m_data),
      .data_ack(m_data_ack),
      .data_seek(m_data_seek),
      .data_req(m_data_req)
  );

  msu_host host (
      .clk_sys(clk_sys),
      .reset(reset),
      .msu_track_num(m_track_num),
      .msu_track_request(m_track_request),
      .msu_audio_req(m_audio_req),
      .msu_audio_seek(m_audio_seek),
      .msu_audio_sector(m_sector),
      .msu_audio_download(audio_download_s),
      .rx_valid(rx_valid & rx_addr[27]),
      .rx_data(rx_data),
      .msu_audio_wr(audio_wr),
      .msu_audio_data(audio_data),
      .msu_track_mounting(m_track_mounting),
      .msu_track_missing(m_track_missing),
      .msu_audio_size(m_audio_size),
      .msu_audio_ack(m_audio_ack),
      .track_req_toggle(track_req_toggle),
      .track_num(track_num),
      .track_resp_toggle(track_resp_toggle),
      .track_size(track_size),
      .sector_req_toggle(sector_req_toggle),
      .sector_num(sector_num)
  );

  wire [15:0] msu_l, msu_r;
  msu_audio audio (
      .reset(reset),
      .clk(clk_sys),
      .clk_rate(21477270),
      .ctl_volume(m_volume),
      .ctl_stop(m_stop),
      .ctl_play(m_playing),
      .ctl_resume(m_resume),
      .ctl_repeat(m_repeat),
      .track_size(m_audio_size),
      .track_processing(m_track_request),
      .audio_download(audio_download_s),
      .audio_data(audio_data),
      .audio_data_wr(audio_wr),
      .audio_ack(m_audio_ack),
      .audio_sector(m_sector),
      .audio_req(m_audio_req),
      .audio_seek(m_audio_seek),
      .resume_sector(m_resume_sector),
      .audio_loop_index(m_loop_index),
      .resume_loop_index(m_resume_loop_index),
      .audio_l(msu_l),
      .audio_r(msu_r)
  );

  wire [24:0] sni_addr;
  wire [15:0] sni_din;
  reg [15:0] sni_dout = 0;
  wire sni_wr_req, sni_rd_req;
  reg sni_ready = 0;
  wire [1:0] copy_req_t, copy_done_t, fill_done_t;
  wire copy_region, seek_region;
  wire [31:0] copy_base;
  wire [13:0] copy_len;

  reg [2:0] stream_mode_s = 0;
  always @(posedge clk_sys) stream_mode_s <= {stream_mode_s[1:0], stream_mode};

  msu_sdram_store #(
      .RING_BITS(RING_BITS)
  ) store (
      .clk_sys(clk_sys),
      .stream_mode(stream_mode_s[2]),
      .seek_req_toggle(seek_req_t),
      .seek_addr(seek_addr),
      .seek_resp_toggle(seek_resp_t),
      .pos_req_toggle(pos_req_t),
      .pos_ack_toggle(pos_ack_t),
      .pos_value(pos_value),
      .pos_seeking(pos_seeking),
      .msu_data_download(msu_data_download_s),
      .load_valid(rx_valid & ~rx_addr[27]),
      .load_addr(rx_addr[13:0]),
      .load_data(rx_data),
      .copy_req_toggle(copy_req_t),
      .copy_region(copy_region),
      .seek_region(seek_region),
      .copy_base(copy_base),
      .copy_len(copy_len),
      .fill_done_toggle(fill_done_t),
      .copy_done_toggle(copy_done_t),
      .rd_addr(m_data_addr),
      .rd_seek(m_data_seek),
      .rd_seek_done(m_data_ack),
      .rd_dout(m_data),
      .sni_addr(sni_addr),
      .sni_din(sni_din),
      .sni_dout(sni_dout),
      .sni_wr_req(sni_wr_req),
      .sni_rd_req(sni_rd_req),
      .sni_ready(sni_ready)
  );

  ////////////////////////////////////////////////////////////////////////////
  // SNI model in clk_mem: ready drops on a request edge, rises after a random delay

  reg [15:0] sdram[0:65535];
  reg old_wr = 0, old_rd = 0;
  integer sni_delay = 0;
  reg sni_is_wr = 0;
  reg [24:0] sni_lat_addr;
  reg [15:0] sni_lat_din;

  always @(posedge clk_mem) begin
    old_wr <= sni_wr_req;
    old_rd <= sni_rd_req;
    if ((sni_wr_req && !old_wr) || (sni_rd_req && !old_rd)) begin
      if (!sni_addr[24] || sni_addr[23:17] != 0) begin
        $display("FAIL: SNI address %h outside test window", sni_addr);
        $finish;
      end
      sni_ready <= 0;
      sni_is_wr <= sni_wr_req;
      sni_lat_addr <= sni_addr;
      sni_lat_din <= sni_din;
      // sdram.sv starts an SNI access in the first idle slot (a ROM access or refresh lasts a
      // few clk_mem) and completes it ~5 clk_mem later
      sni_delay <= 4 + ($urandom % 12);
    end else if (sni_delay > 0) begin
      sni_delay <= sni_delay - 1;
      if (sni_delay == 1) begin
        if (sni_is_wr) sdram[sni_lat_addr[16:1]] <= sni_lat_din;
        else sni_dout <= sdram[sni_lat_addr[16:1]];
        sni_ready <= 1;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////
  // Mock APF

  integer slot_file[0:31];
  integer last_slot = -1;
  integer slot_switches = 0;
  integer errors = 0;

  task automatic bw_raw(input [31:0] addr, input [31:0] raw);
    @(posedge clk_74a);
    bridge_addr <= addr;
    bridge_wr_data <= raw;
    bridge_wr <= 1;
    @(posedge clk_74a);
    bridge_wr <= 0;
  endtask

  task automatic bw(input [31:0] addr, input [31:0] value);
    bw_raw(addr, LITTLE ? bswap(value) : value);
  endtask

  // Like the real bridge: the address moves on after the strobe and the data is sampled
  // later, so the core must hold the word it latched at bridge_rd
  task automatic br_raw(input [31:0] addr, output [31:0] raw);
    @(posedge clk_74a);
    bridge_addr <= addr;
    bridge_rd <= 1;
    @(posedge clk_74a);
    bridge_rd <= 0;
    bridge_addr <= addr[31:28] == 4'hF ? addr : addr + 32'h40;
    repeat (12) @(posedge clk_74a);
    raw = bridge_rd_data;
  endtask

  task automatic br(input [31:0] addr, output [31:0] value);
    reg [31:0] raw;
    br_raw(addr, raw);
    value = LITTLE ? bswap(raw) : raw;
  endtask

  function automatic integer slot_index(input integer id);
    case (id)
      0: return 0;
      10: return 1;
      20: return 2;
      21: return 3;
      default: return -1;
    endcase
  endfunction

  task automatic set_slot_size(input integer id, input integer size);
    bw(32'hF800_2000 + slot_index(id) * 8, id);
    bw(32'hF800_2004 + slot_index(id) * 8, size);
  endtask

  task automatic apf_getfile(input integer slot, input [31:0] ptr);
    string path;
    integer i;
    reg [7:0] b[0:3];
    path = ROM_PATH;
    for (i = 0; i < 256; i = i + 4) begin
      b[0] = i < path.len() ? path[i] : 0;
      b[1] = i + 1 < path.len() ? path[i+1] : 0;
      b[2] = i + 2 < path.len() ? path[i+2] : 0;
      b[3] = i + 3 < path.len() ? path[i+3] : 0;
      bw_raw(ptr + i, pack_struct(b[0], b[1], b[2], b[3]));
    end
  endtask

  task automatic apf_openfile(input integer slot, input [31:0] ptr, output [15:0] result);
    string path;
    reg [31:0] raw;
    reg [7:0] c;
    integer i, done, id;
    reg [31:0] flags;
    path = "";
    done = 0;
    for (i = 0; i < 256 && !done; i = i + 1) begin
      if (i % 4 == 0) br_raw(ptr + i, raw);
      c = STRUCT_LITTLE ? raw[8*(i%4)+:8] : raw[8*(3-i%4)+:8];
      if (c == 0) done = 1;
      else path = {path, string'(c)};
    end
    br(ptr + 32'h100, flags);
    if (flags != 0) begin
      $display("FAIL: openfile flags %h", flags);
      errors = errors + 1;
    end
    id = file_id(path);
    if (REAL) repeat (OPEN_US * 74) @(posedge clk_74a);
    if (!REAL) $display("[%0t] APF openfile slot %0d '%s' -> %0s", $time, slot, path, id ? "found" : "missing");
    if (id == 0) result = 3;
    else begin
      slot_file[slot] = id;
      set_slot_size(slot, file_size(id));
      result = 0;
    end
  endtask

  task automatic apf_read(input integer slot, input [31:0] off, input [31:0] baddr,
                          input [31:0] len, output [15:0] result);
    integer i, id;
    id = slot_file[slot];
    if (id == 0 || off + len > file_size(id)) begin
      result = 2;
      return;
    end
    if (REAL) begin
      repeat (CMD_US * 74) @(posedge clk_74a);
      if (slot != last_slot) repeat (SWITCH_US * 74) @(posedge clk_74a);
      if (slot != last_slot) slot_switches = slot_switches + 1;
      last_slot = slot;
    end
    for (i = 0; i < len; i = i + 4) begin
      bw_raw(baddr + i, pack(file_byte(id, off + i), i + 1 < len ? file_byte(id, off + i + 1) : 0,
                             i + 2 < len ? file_byte(id, off + i + 2) : 0,
                             i + 3 < len ? file_byte(id, off + i + 3) : 0));
      repeat (70) @(posedge clk_74a);
    end
    result = 0;
  endtask

  initial begin : apf
    reg [31:0] t0, p0, p1, p2, p3;
    reg [15:0] result;
    integer i;
    for (i = 0; i < 32; i = i + 1) slot_file[i] = 0;
    slot_file[0] = 9;
    repeat (20) @(posedge clk_74a);
    set_slot_size(0, file_size(9));
    set_slot_size(10, 0);
    set_slot_size(20, 0);
    set_slot_size(21, 0);
    forever begin
      repeat (100) @(posedge clk_74a);
      br(32'hF800_1000, t0);
      if (t0[31:16] == 16'h636D) begin
        br(32'hF800_1020, p0);
        br(32'hF800_1024, p1);
        br(32'hF800_1028, p2);
        br(32'hF800_102C, p3);
        bw(32'hF800_1000, {16'h6275, t0[15:0]});
        repeat (200) @(posedge clk_74a);
        result = 0;
        case (t0[15:0])
          16'h0140: ;
          16'h0190: apf_getfile(p0, p1);
          16'h0192: apf_openfile(p0, p1, result);
          16'h0180: apf_read(p0, p1, p2, p3, result);
          default: begin
            $display("FAIL: unexpected target command %h", t0[15:0]);
            errors = errors + 1;
          end
        endcase
        bw(32'hF800_1000, {16'h6F6B, result});
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////
  // SNES CPU side

  task automatic cpu_write(input [2:0] r, input [7:0] v);
    @(posedge clk_sys);
    cpu_addr <= 24'h002000 | r;
    cpu_dout <= v;
    cpu_wr_n <= 0;
    cpu_ce <= 1;
    @(posedge clk_sys);
    cpu_ce <= 0;
    @(posedge clk_sys);
    cpu_wr_n <= 1;
    repeat (4) @(posedge clk_sys);
  endtask

  task automatic cpu_read(input [2:0] r, output [7:0] v);
    @(posedge clk_sys);
    cpu_addr <= 24'h002000 | r;
    cpu_rd_n <= 0;
    repeat (3) @(posedge clk_sys);
    v = msu_dout;
    cpu_rd_n <= 1;
    // DMA spacing: one byte per 8 master clocks
    repeat (4) @(posedge clk_sys);
  endtask

  task automatic wait_status_clear(input integer bit_i, input string what);
    reg [7:0] st;
    integer n;
    n = 0;
    do begin
      // A frozen console does not poll
      while (store.stall) @(posedge clk_sys);
      cpu_read(0, st);
      n = n + 1;
      if (n > 200000) begin
        $display("FAIL: timeout waiting for %s", what);
        $finish;
      end
    end while (st[bit_i]);
  endtask

  function automatic [15:0] sample(input integer id, input integer k, input integer right);
    integer o;
    o = 8 + 4 * k + (right ? 2 : 0);
    return {file_byte(id, o + 1), file_byte(id, o)};
  endfunction

  // Capture samples as msu_audio pops them from its FIFO
  integer cap_count = 0;
  integer cap_id = 0;
  integer cap_loop = 0;
  integer cap_total = 0;
  integer underflows = 0;
  reg cap_started = 0;
  always @(posedge clk_sys) begin
    if (audio.sample_ce && audio.ctl_play) begin
      if (audio.fifo_empty) begin
        if (cap_started) underflows = underflows + 1;
      end else begin
        integer k;
        cap_started = 1;
        k = cap_count < cap_total ? cap_count : cap_loop + (cap_count - cap_total) % (cap_total - cap_loop);
        if (audio.sample_l !== sample(cap_id, k, 0) || audio.sample_r !== sample(cap_id, k, 1)) begin
          if (errors < 10)
            $display("FAIL: sample %0d (file sample %0d) got %h/%h want %h/%h", cap_count, k, audio.sample_l,
                     audio.sample_r, sample(cap_id, k, 0), sample(cap_id, k, 1));
          errors = errors + 1;
        end
        cap_count = cap_count + 1;
      end
    end
  end

  integer seek_log = 0;
  always @(posedge clk_74a)
    if (SRB && dut_apf.state == 0 && dut_apf.stream_mode && dut_apf.data_seek_pending
        && !(dut_apf.seek_restart && dut_apf.any_outstanding) && seek_log < 40) begin
      seek_log = seek_log + 1;
      $display("[%0t] SEEK page %0d: %s active pages=%0d..%0d/%0d parked=%0d..%0d", $time, dut_apf.seek_addr,
               !dut_apf.seek_restart ? "keep" : dut_apf.seek_in_parked ? "swap" : "restart",
               dut_apf.win_start, dut_apf.win_end, dut_apf.fetch_end, dut_apf.park_start, dut_apf.park_end);
    end
  always @(posedge dut_apf.stream_underrun)
    $display("[%0t] UNDERRUN page=%0d win pages=%0d..%0d fetch_end=%0d park=%0d..%0d seek_waiting=%0d pos=%0d",
             $time, dut_apf.stream_base, dut_apf.win_start, dut_apf.win_end, dut_apf.fetch_end,
             dut_apf.park_start, dut_apf.park_end, dut_apf.seek_waiting, dut_apf.pos_value);

  // Handshake trace
  always @(track_resp_toggle) $display("[%0t] track resp size=%0d", $time, track_size);
  always @(sector_req_toggle) $display("[%0t] sector req %0d", $time, sector_num);
  always @(posedge audio_download) $display("[%0t] audio_download up, len=%0d off=%0d", $time, dut_apf.read_length, dut_apf.read_offset);
  always @(posedge m_stop) $display("[%0t] msu_audio stop, sector=%0d size=%0d", $time, m_sector, m_audio_size);

  realtime seek_t0, seek_max = 0;
  // The store freezes the console during slow seeks: the game's poll loop does not run then,
  // so frozen time does not count against its timeout
  realtime stall_t0, stall_acc = 0, stall_max = 0, stall_acc0;
  always @(posedge store.stall) stall_t0 = $realtime;
  always @(negedge store.stall) begin
    stall_acc = stall_acc + ($realtime - stall_t0);
    if ($realtime - stall_t0 > stall_max) stall_max = $realtime - stall_t0;
  end

  task automatic srb_seek(input integer addr);
    cpu_write(0, addr[7:0]);
    cpu_write(1, addr[15:8]);
    cpu_write(2, addr[23:16]);
    cpu_write(3, 0);
    seek_t0 = $realtime;
    stall_acc0 = stall_acc;
    wait_status_clear(7, "data busy (SRB seek)");
    if ($realtime - seek_t0 - (stall_acc - stall_acc0) > seek_max)
      seek_max = $realtime - seek_t0 - (stall_acc - stall_acc0);
  endtask

  task automatic srb_read(input integer addr, input integer n);
    reg [7:0] v;
    integer i;
    for (i = 0; i < n; i = i + 1) begin
      cpu_read(1, v);
      if (v !== file_byte(1, addr + i)) begin
        if (errors < 10) $display("FAIL: SRB data[%0d] got %h want %h", addr + i, v, file_byte(1, addr + i));
        errors = errors + 1;
      end
    end
  endtask

  integer open_max_us = 0;
  task automatic track_open(input integer t, output reg missing);
    reg [7:0] st;
    realtime t0;
    cpu_write(4, t[7:0]);
    cpu_write(5, t[15:8]);
    t0 = $realtime;
    wait_status_clear(6, "audio busy (track open)");
    if (($realtime - t0) / 1000.0 > open_max_us) open_max_us = ($realtime - t0) / 1000.0;
    cpu_read(0, st);
    missing = st[3];
  endtask

  // z3randomizer msu.asm: identify, detect packs (tracks 1, 101, ...), scan 64 tracks for SPC
  // fallback, then play with fades, stop with resume, play another, and resume the first
  task automatic z3r_pattern();
    reg missing;
    reg [7:0] v;
    integer t, i, resume_sample;
    string ident;
    ident = "";
    for (i = 2; i < 8; i = i + 1) begin
      cpu_read(i, v);
      ident = {ident, string'(v)};
    end
    if (ident != "S-MSU1") begin
      $display("FAIL: ident '%s'", ident);
      errors = errors + 1;
    end
    track_open(1, missing);
    if (missing) begin $display("FAIL: pack track 1 missing"); errors = errors + 1; end
    track_open(101, missing);
    if (!missing) begin $display("FAIL: track 101 should be missing"); errors = errors + 1; end
    for (t = 64; t >= 1; t = t - 1) begin
      track_open(t, missing);
      if (missing != !(t == 1 || t == 2 || t == 12 || t == 34)) begin
        $display("FAIL: track %0d missing=%0d", t, missing);
        errors = errors + 1;
      end
    end
    $display("[%0t] z3r: 66 track opens, longest %0d us", $time, open_max_us);

    // Track 34 with repeat, fading in one volume step per "frame"
    track_open(34, missing);
    cpu_write(6, 0);
    cap_count = 0;
    cap_id = 5;
    cap_total = T34_SAMPLES;
    cap_loop = T34_LOOP;
    cap_started = 0;
    cpu_write(7, 8'h03);
    for (i = 0; i < 16; i = i + 1) begin
      cpu_write(6, i * 16 + 15);
      #1_000_000;
    end
    while (cap_count < 1500) @(posedge clk_sys);
    // Stop with resume, as when a room's music is interrupted
    cpu_write(7, 8'h04);
    resume_sample = m_resume_sector * 256 - 2;
    $display("[%0t] z3r: track 34 stopped with resume after %0d samples, resumes at sample %0d", $time,
             cap_count, resume_sample);
    track_open(2, missing);
    cap_count = 0;
    cap_id = 4;
    cap_total = T2_SAMPLES;
    cap_loop = 0;
    cap_started = 0;
    cpu_write(6, 8'hFF);
    cpu_write(7, 8'h01);
    while (cap_count < 300) @(posedge clk_sys);
    cpu_write(7, 8'h00);
    // Back to track 34: MSU.sv resumes it from the saved sector
    track_open(34, missing);
    cap_count = resume_sample;
    cap_id = 5;
    cap_total = T34_SAMPLES;
    cap_loop = T34_LOOP;
    cap_started = 0;
    cpu_write(7, 8'h03);
    while (cap_count < resume_sample + 800) @(posedge clk_sys);
    cpu_write(7, 8'h00);
    $display("[%0t] z3r: track 34 resumed and played to sample %0d", $time, cap_count);
  endtask

  // MSU-1 video player: header at 0, then one seek and VIDEO_KB per vblank at 60Hz while
  // music loops; the stream must never fall behind
  task automatic video_pattern();
    integer f, addr;
    realtime t0;
    cpu_write(6, 8'hFF);
    cpu_write(4, 1);
    cpu_write(5, 0);
    wait_status_clear(6, "audio busy (video music)");
    cap_count = 0;
    cap_id = 2;
    cap_total = T1_SAMPLES;
    cap_loop = 0;
    cap_started = 0;
    cpu_write(7, 8'h03);
    srb_seek(0);
    srb_read(0, 64);
    addr = 4096;
    srb_seek(addr);
    for (f = 0; f < 60 && addr + VIDEO_KB * 1024 < MSU_SIZE; f = f + 1) begin
      t0 = $realtime;
      srb_read(addr, VIDEO_KB * 1024);
      addr = addr + VIDEO_KB * 1024;
      while ($realtime - t0 < 16_667_000.0) @(posedge clk_sys);
    end
    cpu_write(7, 8'h00);
    $display("[%0t] video: %0d frames of %0dKB at 60Hz (%0d KB/s), %0d slot switches, %0d samples", $time, f,
             VIDEO_KB, VIDEO_KB * 60, slot_switches, cap_count);
  endtask

  // Header and chapter pointer at the file start, then per frame: the chapter's frame table,
  // the frame's data, and its palette, with track 1 looping meanwhile
  task automatic srb_pattern();
    integer f, chapter, frame;
    reg [7:0] st;
    cpu_write(6, 8'hFF);
    cpu_write(4, 1);
    cpu_write(5, 0);
    wait_status_clear(6, "audio busy (SRB music)");
    cap_count = 0;
    cap_id = 2;
    cap_total = T1_SAMPLES;
    cap_loop = 0;
    cap_started = 0;
    cpu_write(7, 8'h03);
    srb_seek(0);
    srb_read(0, 64);
    srb_seek('h100);
    srb_read('h100, 4);
    chapter = 60000;
    for (f = 0; f < 30; f = f + 1) begin
      frame = chapter + 'h2000 + f * 6000;
      srb_seek(chapter + 4 * f);
      srb_read(chapter + 4 * f, 4);
      srb_seek(frame);
      srb_read(frame, 2000);
      srb_seek(frame + 5000);
      srb_read(frame + 5000, 256);
    end
    cpu_write(7, 8'h00);
    $display("[%0t] SRB pattern: 92 seeks, longest %0.1f us of game time (budget %0d us), longest freeze %0.1f us, %0d slot switches, %0d samples",
             $time, seek_max / 1000.0, SEEK_BUDGET_US, stall_max / 1000.0, slot_switches, cap_count);
    if (seek_max > SEEK_BUDGET_US * 1000.0) begin
      $display("FAIL: a seek took longer than the game allows");
      errors = errors + 1;
    end
  endtask
  initial begin : test
    reg [7:0] v, st;
    integer i, base;
    $dumpfile("tb_msu.vcd");
    $dumpvars(1, tb_msu);

    repeat (50) @(posedge clk_74a);
    // ROM then save load from the chip32 loader
    ioctl_download <= 1;
    repeat (500) @(posedge clk_74a);
    ioctl_download <= 0;
    repeat (50) @(posedge clk_74a);
    ioctl_download <= 1;
    repeat (100) @(posedge clk_74a);
    ioctl_download <= 0;

    wait (msu_busy);
    wait (!msu_busy);
    $display("[%0t] probe done: msu_enable=%0d status=%0d", $time, msu_enable, probe_status);
    if (probe_status != (HAVE_MSU ? 1 : 4)) begin
      $display("FAIL: probe_status %0d", probe_status);
      errors = errors + 1;
    end

    if (!HAVE_MSU) begin
      if (msu_enable) begin
        $display("FAIL: MSU enabled without a .msu file");
        errors = errors + 1;
      end
      cpu_read(2, v);
      if (v == "S") begin
        $display("FAIL: MSU registers visible while disabled");
        errors = errors + 1;
      end
    end else begin
      if (!msu_enable) begin
        $display("FAIL: MSU not enabled");
        $finish;
      end
      if (STREAM) begin
        if (!stream_mode) begin
          $display("FAIL: a %0d-byte .msu should stream", MSU_SIZE);
          errors = errors + 1;
        end
      end else begin
        for (i = 0; i < MSU_SIZE; i = i + 1)
          if ((i[0] ? sdram[i>>1][15:8] : sdram[i>>1][7:0]) !== file_byte(1, i)) begin
            if (errors < 10) $display("FAIL: sdram byte %0d", i);
            errors = errors + 1;
          end
        $display("[%0t] .msu preload checked (%0d bytes)", $time, MSU_SIZE);
      end

      repeat (20) @(posedge clk_sys);
      // Identification string
      cpu_read(2, v);
      if (v != "S") begin
        $display("FAIL: ident %h", v);
        errors = errors + 1;
      end

      // Data port: seek, wait for busy to clear, stream bytes
      for (base = 'h123; !REAL && base < MSU_SIZE; base = base + 'h4D1) begin
        cpu_write(0, base[7:0]);
        cpu_write(1, base[15:8]);
        cpu_write(2, 0);
        cpu_write(3, 0);
        seek_t0 = $realtime;
        wait_status_clear(7, "data busy");
        if ($realtime - seek_t0 > seek_max) seek_max = $realtime - seek_t0;
        for (i = 0; i < 600 && base + i < MSU_SIZE; i = i + 1) begin
          cpu_read(1, v);
          if (v !== file_byte(1, base + i)) begin
            if (errors < 10) $display("FAIL: data[%0d] got %h want %h", base + i, v, file_byte(1, base + i));
            errors = errors + 1;
          end
        end
      end
      if (SRB) srb_pattern();
      if (Z3R) z3r_pattern();
      if (VIDEO) video_pattern();
      if (STREAM && !REAL) begin
        // One long read across several ring wraps while chunks refill behind it
        base = 5000;
        cpu_write(0, base[7:0]);
        cpu_write(1, base[15:8]);
        cpu_write(2, 0);
        cpu_write(3, 0);
        wait_status_clear(7, "data busy (long read)");
        for (i = 0; i < 20000; i = i + 1) begin
          cpu_read(1, v);
          if (v !== file_byte(1, base + i)) begin
            if (errors < 10) $display("FAIL: stream data[%0d] got %h want %h", base + i, v, file_byte(1, base + i));
            errors = errors + 1;
          end
        end
        $display("[%0t] streamed 20000 bytes across the %0d-byte ring", $time, 1 << RING_BITS);
      end
      $display("[%0t] data port checked, longest seek %0.1f us", $time, seek_max / 1000.0);

      // Generic audio checks; the realistic scenarios cover their own track sets
      if (!REAL) begin
      // Missing track
      cpu_write(4, 2);
      cpu_write(5, 0);
      wait_status_clear(6, "audio busy (track 2)");
      cpu_read(0, st);
      if (!st[3]) begin
        $display("FAIL: track 2 should be missing (status %h)", st);
        errors = errors + 1;
      end

      // Track 1, no repeat: every sample once, then stop
      cpu_write(6, 8'hFF);
      cpu_write(4, 1);
      cpu_write(5, 0);
      wait_status_clear(6, "audio busy (track 1)");
      cpu_read(0, st);
      if (st[3]) begin
        $display("FAIL: track 1 reported missing");
        errors = errors + 1;
      end
      cap_count = 0;
      cap_id = 2;
      cap_total = T1_SAMPLES;
      cap_loop = 0;
      cap_started = 0;
      cpu_write(7, 8'h01);
      wait_status_clear(4, "track 1 to finish");
      // Upstream msu_audio stops once the last sector is fetched, dropping what is
      // still queued (under 768 samples), so only a correct prefix is required.
      if (cap_count > T1_SAMPLES || cap_count < T1_SAMPLES - 768 || cap_count == 0) begin
        $display("FAIL: track 1 played %0d samples of %0d", cap_count, T1_SAMPLES);
        errors = errors + 1;
      end
      $display("[%0t] track 1 played %0d samples, %0d underflows", $time, cap_count, underflows);

      // Track 12, repeat: plays through and wraps to the loop point
      underflows = 0;
      cpu_write(4, 12);
      cpu_write(5, 0);
      wait_status_clear(6, "audio busy (track 12)");
      cap_count = 0;
      cap_id = 3;
      cap_total = T12_SAMPLES;
      cap_loop = T12_LOOP;
      cap_started = 0;
      cpu_write(7, 8'h03);
      while (cap_count < T12_SAMPLES * 2 + 50) @(posedge clk_sys);
      cpu_write(7, 8'h00);
      $display("[%0t] track 12 looped through %0d samples, %0d underflows", $time, cap_count, underflows);
      if (underflows > 4) begin
        $display("FAIL: %0d FIFO underflows while looping", underflows);
        errors = errors + 1;
      end
      end
    end

    if (stream_underrun) begin
      $display("FAIL: stream underrun");
      errors = errors + 1;
    end
    if (errors == 0) $display("PASS (LITTLE=%0d HAVE_MSU=%0d)", LITTLE, HAVE_MSU);
    else $display("FAIL: %0d errors (LITTLE=%0d HAVE_MSU=%0d)", errors, LITTLE, HAVE_MSU);
    $finish;
  end

  initial begin
    if (SWITCH_US > 10000) #10_000_000_000;  // slow-SD case: tens of ms per slot switch
    else #2_000_000_000;
    $display("FAIL: global timeout");
    $finish;
  end
endmodule
