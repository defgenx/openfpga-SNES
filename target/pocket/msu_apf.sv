// MSU-1 file access over APF target commands: the Pocket stand-in for the MiSTer HPS
// side of MSU-1 (Main_MiSTer support/snes/snes.cpp). See docs/MSU-1.md.
//
// All logic is in clk_74a. Requests from the SNES side (clk_sys) arrive as toggles
// whose payload the sender holds stable until the matching response.
module msu_apf #(
    parameter [15:0] DATA_SLOT_ID = 16'd20,
    parameter [15:0] AUDIO_SLOT_ID = 16'd21,
    parameter [3:0] SCRATCH_REGION = 4'h3,
    parameter [31:0] DATA_BRIDGE_ADDR = 32'h4000_0000,
    // Same data_loader as the data file; bit 27 routes the words to msu_audio
    parameter [31:0] AUDIO_BRIDGE_ADDR = 32'h4800_0000,
    // Bytes of the .msu file that fit in SDRAM banks 2-3
    parameter [31:0] DATA_MAX_SIZE = 32'h0100_0000,
    // Quiet time after the last ROM/save load before probing (2^20 cycles ~ 14ms)
    parameter QUIET_BITS = 20,
    // Give up on an unanswered target command during the boot probe (2^26 ~ 0.9s)
    parameter TIMEOUT_BITS = 26
) (
    input wire clk_74a,

    // ROM/save load from the chip32 loader; the SNES is held in reset while this probes
    input wire ioctl_download,
    // core_bridge_cmd reset_n: target commands are only serviced once the core runs
    input wire core_running,

    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire bridge_wr,
    input wire [31:0] bridge_wr_data,
    output reg [31:0] scratch_rd_data,

    // core_bridge_cmd target interface
    output reg target_dataslot_read = 0,
    output reg target_dataslot_getfile = 0,
    output reg target_dataslot_openfile = 0,
    input wire target_dataslot_done,
    input wire [2:0] target_dataslot_err,
    output reg [15:0] target_dataslot_id = 0,
    output reg [31:0] target_dataslot_slotoffset = 0,
    output reg [31:0] target_dataslot_bridgeaddr = 0,
    output reg [31:0] target_dataslot_length = 0,

    // Data slot size table (core_bridge_cmd port A); core_top yields it while dt_active
    output reg dt_active = 0,
    output reg [9:0] dt_addr = 0,
    input wire [31:0] dt_q,

    // Levels, synchronized by the receiver
    output reg msu_busy = 0,  // hold the SNES in reset
    output reg msu_enable = 0,  // a <rom>.msu file exists
    output reg msu_data_download = 0,  // .msu bytes are streaming into SDRAM
    output reg audio_download = 0,  // a .pcm sector is streaming into msu_audio

    // Track open: request toggle + number in, response toggle + file size out (0 = missing)
    input wire track_req_toggle,
    input wire [15:0] track_num,
    output reg track_resp_toggle = 0,
    output reg [31:0] track_size = 0,

    // Audio sector read: 1024 bytes at sector * 1024
    input wire sector_req_toggle,
    input wire [21:0] sector_num
);
  localparam S_IDLE = 0;
  localparam S_GETFILE_DONE = 1;
  localparam S_SCAN_WAIT = 2;
  localparam S_SCAN = 3;
  localparam S_DIGITS = 4;
  localparam S_SUFFIX = 6;
  localparam S_SUFFIX_ADDR = 7;
  localparam S_SUFFIX_WAIT = 8;
  localparam S_SUFFIX_WR = 9;
  localparam S_FLAGS = 10;
  localparam S_OPEN_DONE = 11;
  localparam S_SIZE_WAIT = 12;
  localparam S_SIZE_CHECK = 13;
  localparam S_AFTER_OPEN = 14;
  localparam S_READ = 15;
  localparam S_DRAIN = 16;
  localparam S_CMD = 17;
  localparam S_CMD_WAIT_LOW = 18;
  localparam S_CMD_WAIT_HIGH = 19;

  reg [4:0] state = S_IDLE;
  reg [4:0] cmd_return;

  wire apf_owns_scratch = state == S_CMD_WAIT_LOW || state == S_CMD_WAIT_HIGH;

  ////////////////////////////////////////////////////////////////////////////
  // Scratch RAM for the get/open filename structs (path at 0x0, flags at 0x100).
  // Single port: APF only touches it while a command is outstanding.

  reg [31:0] scratch[0:127];
  reg [6:0] fsm_addr = 0;
  reg [31:0] fsm_wdata;
  reg fsm_we = 0;

  wire [6:0] scratch_addr = apf_owns_scratch ? bridge_addr[8:2] : fsm_addr;
  wire scratch_we = apf_owns_scratch ? bridge_wr && bridge_addr[31:28] == SCRATCH_REGION : fsm_we;
  wire [31:0] scratch_wdata = apf_owns_scratch ? bridge_wr_data : fsm_wdata;

  always @(posedge clk_74a) begin
    if (scratch_we) scratch[scratch_addr] <= scratch_wdata;
    scratch_rd_data <= scratch[scratch_addr];
  end

  wire [31:0] fsm_q = scratch_rd_data;

  // Byte i of the path lives in word i>>2; the lane follows bridge endianness the
  // same way data_loader.sv unpacks file bytes.
  reg [2:0] endian_s = 0;
  wire little = endian_s[2];

  function automatic [4:0] lane_shift(input [1:0] i, input little_endian);
    lane_shift = {little_endian ? i : 2'd3 - i, 3'b000};
  endfunction

  ////////////////////////////////////////////////////////////////////////////
  // Request synchronizers

  reg [2:0] track_req_s = 0;
  reg [2:0] sector_req_s = 0;
  reg track_req_seen = 0;
  reg sector_req_seen = 0;

  always @(posedge clk_74a) begin
    track_req_s <= {track_req_s[1:0], track_req_toggle};
    sector_req_s <= {sector_req_s[1:0], sector_req_toggle};
    endian_s <= {endian_s[1:0], bridge_endian_little};
  end

  wire track_pending = track_req_s[2] != track_req_seen;
  wire sector_pending = sector_req_s[2] != sector_req_seen;

  ////////////////////////////////////////////////////////////////////////////
  // FSM

  localparam OP_PROBE = 0;
  localparam OP_TRACK = 1;
  localparam OP_SECTOR = 2;
  reg [1:0] op = OP_PROBE;

  localparam CMD_READ = 0;
  localparam CMD_GETFILE = 1;
  localparam CMD_OPENFILE = 2;
  reg [1:0] cmd = CMD_READ;
  reg [2:0] cmd_err = 0;
  reg cmd_timed_out = 0;
  reg [TIMEOUT_BITS-1:0] cmd_timer = 0;
  wire cmd_ok = cmd_err == 0 && !cmd_timed_out;

  reg prev_download = 0;
  reg probe_pending = 0;
  reg [QUIET_BITS-1:0] quiet = 0;

  reg [7:0] idx;  // byte index into the path
  reg [7:0] base_len;  // path length without the ROM extension
  reg [7:0] last_dot;
  reg have_dot;

  // Written after base_len: ".msu" or "-<n>.pcm", then NUL
  reg [3:0] suffix_idx;
  reg [15:0] digit_value;
  reg [2:0] digit_pos;
  reg [3:0] digit;
  reg [19:0] digits;  // emitted decimal digits, most significant in the highest used nibble
  reg [2:0] ndigits;

  wire [3:0] suffix_len = op == OP_PROBE ? 4'd5 : 4'd6 + ndigits;

  function automatic [7:0] ext_char(input [2:0] i, input probe);
    case (i)
      0: ext_char = probe ? "." : "-";
      default: ext_char = 8'h00;
    endcase
    if (probe)
      case (i)
        1: ext_char = "m";
        2: ext_char = "s";
        3: ext_char = "u";
        default: ;
      endcase
  endfunction

  function automatic [7:0] pcm_char(input [2:0] i);
    case (i)
      0: pcm_char = ".";
      1: pcm_char = "p";
      2: pcm_char = "c";
      3: pcm_char = "m";
      default: pcm_char = 8'h00;
    endcase
  endfunction

  wire [3:0] digit_k = suffix_idx - 1'd1;  // digit index, most significant first
  wire [3:0] digit_at = digits[{ndigits - 1'd1 - digit_k[2:0], 2'b00}+:4];
  wire [7:0] suffix_char =
      op == OP_PROBE ? ext_char(suffix_idx[2:0], 1'b1)
      : suffix_idx == 0 ? "-"
      : suffix_idx <= ndigits ? "0" + digit_at
      : pcm_char(suffix_idx - ndigits - 1'd1);

  reg [31:0] slot_size;
  reg [1:0] dt_wait;

  reg [31:0] read_offset;
  reg [31:0] read_length;
  reg [9:0] drain;

  wire [15:0] opened_slot = op == OP_PROBE ? DATA_SLOT_ID : AUDIO_SLOT_ID;
  wire [7:0] scan_byte = fsm_q[lane_shift(idx[1:0], little)+:8];
  wire [31:0] sector_offset = {sector_num, 10'b0};
  // Full sectors, then the remainder, then nothing past the end
  wire [21:0] last_sector = track_size[31:10];
  wire [10:0] sector_length = sector_num < last_sector ? 11'd1024
      : sector_num == last_sector ? {1'b0, track_size[9:0]} : 11'd0;

  function automatic [15:0] pow10(input [2:0] pos);
    case (pos)
      0: pow10 = 16'd10000;
      1: pow10 = 16'd1000;
      2: pow10 = 16'd100;
      3: pow10 = 16'd10;
      default: pow10 = 16'd1;
    endcase
  endfunction

  always @(posedge clk_74a) begin
    fsm_we <= 0;
    target_dataslot_read <= 0;
    target_dataslot_getfile <= 0;
    target_dataslot_openfile <= 0;

    prev_download <= ioctl_download;
    if (ioctl_download && ~prev_download) begin
      probe_pending <= 1;
      msu_busy <= 1;
      msu_enable <= 0;
    end

    if (ioctl_download) quiet <= 0;
    else if (~&quiet) quiet <= quiet + 1'd1;

    case (state)
      S_IDLE: begin
        if (probe_pending && &quiet && core_running) begin
          probe_pending <= 0;
          op <= OP_PROBE;
          cmd <= CMD_GETFILE;
          target_dataslot_id <= 0;
          cmd_return <= S_GETFILE_DONE;
          state <= S_CMD;
        end else if (msu_enable && track_pending) begin
          track_req_seen <= track_req_s[2];
          op <= OP_TRACK;
          digit_value <= track_num;
          digit_pos <= 0;
          digit <= 0;
          ndigits <= 0;
          state <= S_DIGITS;
        end else if (msu_enable && sector_pending) begin
          sector_req_seen <= sector_req_s[2];
          op <= OP_SECTOR;
          read_offset <= sector_offset;
          read_length <= sector_length;
          audio_download <= 1;
          drain <= 0;
          state <= S_READ;
        end else if (!msu_enable) begin
          // Requests while MSU is off are dropped, like hps_ext
          track_req_seen <= track_req_s[2];
          sector_req_seen <= sector_req_s[2];
        end
      end

      // getfile(slot 0) left the ROM path in scratch: find its end and extension
      S_GETFILE_DONE: begin
        if (!cmd_ok) begin
          state <= S_AFTER_OPEN;
        end else begin
          idx <= 0;
          have_dot <= 0;
          fsm_addr <= 0;
          state <= S_SCAN_WAIT;
        end
      end

      S_SCAN_WAIT: state <= S_SCAN;

      S_SCAN: begin
        if (scan_byte == 8'h00) begin
          base_len <= have_dot ? last_dot : idx;
          state <= S_SUFFIX;
        end else if (idx == 8'd255) begin
          // No terminator inside the struct
          cmd_err <= 3'd4;
          state <= S_AFTER_OPEN;
        end else begin
          if (scan_byte == "/") have_dot <= 0;
          if (scan_byte == ".") begin
            have_dot <= 1;
            last_dot <= idx;
          end
          idx <= idx + 1'd1;
          fsm_addr <= (idx + 1'd1) >> 2;
          state <= S_SCAN_WAIT;
        end
      end

      // Track number to decimal, no leading zeros (MiSTer formats it with %d)
      S_DIGITS: begin
        if (digit_value >= pow10(digit_pos)) begin
          digit_value <= digit_value - pow10(digit_pos);
          digit <= digit + 1'd1;
        end else begin
          if (digit != 0 || ndigits != 0 || digit_pos == 4) begin
            digits <= {digits[15:0], digit};
            ndigits <= ndigits + 1'd1;
          end
          digit <= 0;
          digit_pos <= digit_pos + 1'd1;
          if (digit_pos == 4) state <= S_SUFFIX;
        end
      end

      // Read-modify-write each suffix byte into the path after base_len
      S_SUFFIX: begin
        if (base_len > 8'd244) begin
          cmd_err <= 3'd4;
          state <= S_AFTER_OPEN;
        end else begin
          suffix_idx <= 0;
          idx <= base_len;
          state <= S_SUFFIX_ADDR;
        end
      end

      S_SUFFIX_ADDR: begin
        fsm_addr <= idx >> 2;
        state <= S_SUFFIX_WAIT;
      end

      S_SUFFIX_WAIT: state <= S_SUFFIX_WR;

      S_SUFFIX_WR: begin
        fsm_wdata <= fsm_q;
        fsm_wdata[lane_shift(idx[1:0], little)+:8] <= suffix_char;
        fsm_we <= 1;
        if (suffix_idx == suffix_len - 1'd1) begin
          idx <= 0;
          state <= S_FLAGS;
        end else begin
          suffix_idx <= suffix_idx + 1'd1;
          idx <= idx + 1'd1;
          state <= S_SUFFIX_ADDR;
        end
      end

      // Zero flags (0x100) and size (0x104): open an existing file, no create/resize
      S_FLAGS: begin
        fsm_addr <= idx == 0 ? 7'd64 : 7'd65;
        fsm_wdata <= 0;
        fsm_we <= 1;
        if (idx == 0) idx <= 1;
        else begin
          cmd <= CMD_OPENFILE;
          target_dataslot_id <= opened_slot;
          cmd_return <= S_OPEN_DONE;
          state <= S_CMD;
        end
      end

      // Look the opened slot's size up in the data slot table
      S_OPEN_DONE: begin
        slot_size <= 0;
        if (!cmd_ok) begin
          state <= S_AFTER_OPEN;
        end else begin
          dt_active <= 1;
          dt_addr <= 0;
          dt_wait <= 0;
          state <= S_SIZE_WAIT;
        end
      end

      S_SIZE_WAIT: begin
        dt_wait <= dt_wait + 1'd1;
        if (&dt_wait) state <= S_SIZE_CHECK;
      end

      S_SIZE_CHECK: begin
        if (dt_addr[0]) begin
          slot_size <= dt_q;
          state <= S_AFTER_OPEN;
        end else if (dt_q[15:0] == opened_slot) begin
          dt_addr <= dt_addr + 1'd1;
          state <= S_SIZE_WAIT;
        end else if (dt_addr == 10'd62) begin
          state <= S_AFTER_OPEN;
        end else begin
          dt_addr <= dt_addr + 10'd2;
          state <= S_SIZE_WAIT;
        end
      end

      S_AFTER_OPEN: begin
        dt_active <= 0;
        if (op == OP_PROBE) begin
          // MiSTer enables MSU-1 whenever <rom>.msu exists, even an empty one
          msu_enable <= cmd_ok;
          if (cmd_ok && slot_size != 0) begin
            read_offset <= 0;
            read_length <= slot_size > DATA_MAX_SIZE ? DATA_MAX_SIZE : slot_size;
            msu_data_download <= 1;
            drain <= 0;
            state <= S_READ;
          end else begin
            msu_busy <= 0;
            state <= S_IDLE;
          end
        end else begin
          track_size <= cmd_ok ? slot_size : 32'd0;
          track_resp_toggle <= ~track_resp_toggle;
          state <= S_IDLE;
        end
      end

      S_READ: begin
        // Let the download level cross into clk_sys before data arrives
        drain <= drain + 1'd1;
        if (drain == 10'd31) begin
          if (read_length == 0) begin
            state <= S_DRAIN;
          end else begin
            cmd <= CMD_READ;
            target_dataslot_id <= opened_slot;
            target_dataslot_slotoffset <= read_offset;
            target_dataslot_bridgeaddr <= op == OP_PROBE ? DATA_BRIDGE_ADDR : AUDIO_BRIDGE_ADDR;
            target_dataslot_length <= read_length;
            cmd_return <= S_DRAIN;
            state <= S_CMD;
          end
        end
      end

      S_DRAIN: begin
        // data_loader's FIFO and the clk_sys write path empty well within this
        drain <= drain + 1'd1;
        if (&drain) begin
          msu_data_download <= 0;
          audio_download <= 0;
          if (op == OP_PROBE) msu_busy <= 0;
          state <= S_IDLE;
        end
      end

      // core_bridge_cmd drops done when it starts the command and raises it at the end
      S_CMD: begin
        cmd_timer <= 0;
        cmd_timed_out <= 0;
        cmd_err <= 0;
        case (cmd)
          CMD_READ: target_dataslot_read <= 1;
          CMD_GETFILE: target_dataslot_getfile <= 1;
          default: target_dataslot_openfile <= 1;
        endcase
        state <= S_CMD_WAIT_LOW;
      end

      S_CMD_WAIT_LOW: begin
        cmd_timer <= cmd_timer + 1'd1;
        if (!target_dataslot_done) state <= S_CMD_WAIT_HIGH;
        else if (op == OP_PROBE && &cmd_timer) begin
          cmd_timed_out <= 1;
          state <= cmd_return;
        end
      end

      S_CMD_WAIT_HIGH: begin
        cmd_timer <= cmd_timer + 1'd1;
        if (target_dataslot_done) begin
          cmd_err <= target_dataslot_err;
          state <= cmd_return;
        end else if (op == OP_PROBE && &cmd_timer) begin
          cmd_timed_out <= 1;
          state <= cmd_return;
        end
      end

      default: state <= S_IDLE;
    endcase
  end

endmodule
