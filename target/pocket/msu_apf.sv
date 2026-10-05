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
    // Same bridge region as the data file; bit 27 routes the words to msu_audio
    parameter [31:0] AUDIO_BRIDGE_ADDR = 32'h4800_0000,
    // SDRAM banks 2-3 hold 2^RING_BITS bytes of the .msu file. A file up to DATA_MAX_SIZE is
    // copied whole at boot; a larger one is streamed through them as a ring (file byte X at
    // X mod 2^RING_BITS), see docs/MSU-1.md "Streaming"
    parameter RING_BITS = 24,
    parameter [31:0] DATA_MAX_SIZE = 32'h0100_0000,
    // Games time a seek out (Super Road Blaster: "Timeout while seeking"), so a seek completes
    // once STREAM_LEAD bytes past it are in, fetched as one read; chunks stay small so one
    // already in flight delays a seek only briefly
    parameter [31:0] STREAM_CHUNK = 32'h0000_2000,  // bytes per .msu read; at most the bounce buffer
    parameter [31:0] STREAM_LEAD = 32'h0000_1000,  // buffered past a seek before it completes
    parameter [31:0] STREAM_GUARD = 32'h0010_0000,  // ring space kept free behind the reader
    // Read-ahead past the reader. Fetching only this far keeps SDRAM writes near the game's
    // read rate, so they rarely compete with its reads
    parameter [31:0] STREAM_AHEAD = 32'h0004_0000,  // must stay below RING_SIZE - STREAM_GUARD
    // Quiet time after the last ROM/save load before probing (2^20 cycles ~ 14ms)
    parameter QUIET_BITS = 20,
    // Give up on an unanswered target command during the boot probe: Get/Open File after
    // 2^29 cycles (~7s), the .msu copy (up to 16MB, several seconds) after 2^30 (~14s)
    parameter TIMEOUT_BITS = 30
) (
    input wire clk_74a,

    // ROM/save load from the chip32 loader; the SNES is held in reset while this probes
    input wire ioctl_download,
    // core_bridge_cmd reset_n: target commands are only serviced once the core runs
    input wire core_running,

    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire bridge_rd,
    input wire bridge_wr,
    input wire [31:0] bridge_wr_data,
    output reg [31:0] scratch_rd_data,

    // core_bridge_cmd target interface
    output reg target_dataslot_read = 0,
    output reg target_dataslot_getfile = 0,
    output reg target_dataslot_openfile = 0,
    input wire target_dataslot_done,
    input wire [2:0] target_dataslot_err,
    output wire [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output wire [31:0] target_dataslot_bridgeaddr,
    output wire [31:0] target_dataslot_length,

    // Data slot size table (core_bridge_cmd port A); core_top yields it while dt_active
    output reg dt_active = 0,
    output reg [9:0] dt_addr = 0,
    input wire [31:0] dt_q,

    // Levels, synchronized by the receiver
    output reg msu_busy = 0,  // hold the SNES in reset
    output reg msu_enable = 0,  // a <rom>.msu file exists
    output reg msu_data_download = 0,  // .msu bytes are streaming into SDRAM
    output reg audio_download = 0,  // a .pcm sector is streaming into msu_audio
    // Boot probe result for the on-screen diagnostic, see docs/MSU-1.md
    output reg [3:0] probe_status = 0,

    // Track open: request toggle + number in, response toggle + file size out (0 = missing)
    input wire track_req_toggle,
    input wire [15:0] track_num,
    output reg track_resp_toggle = 0,
    output reg [31:0] track_size = 0,

    // Audio sector read: 1024 bytes at sector * 1024
    input wire sector_req_toggle,
    input wire [21:0] sector_num,

    // Streaming (.msu larger than DATA_MAX_SIZE): seek request toggle + offset in, response
    // once STREAM_LEAD bytes past it are in SDRAM; the reader's position on request
    output reg stream_mode = 0,
    output reg stream_underrun = 0,  // diagnostic: the game read past the buffered data
    output reg [5:0] stream_fill = 0,  // diagnostic: buffered bytes past the reader, in STREAM_AHEAD/64

    // Every .msu read lands in msu_sdram_store's bounce buffer; this asks it to copy the chunk
    // to SDRAM, and the next read waits for copy_done_toggle
    output reg copy_req_toggle = 0,
    output reg copy_bank = 0,  // double buffer: APF fills one bank while the other is copied
    output reg [31:0] copy_base = 0,
    output reg [13:0] copy_len = 0,
    input wire copy_done_toggle,
    input wire data_seek_req_toggle,
    input wire [31:0] data_seek_addr,
    output reg data_seek_resp_toggle = 0,
    output reg pos_req_toggle = 0,
    input wire pos_ack_toggle,
    input wire [31:0] pos_value
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
  localparam S_DETECT_WAIT = 20;
  localparam S_DETECT = 21;
  localparam S_POS_WAIT = 22;
  localparam S_FETCH = 23;
  localparam S_PRELOAD = 24;
  localparam S_COPY_WAIT = 25;

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

  // APF samples read data well after bridge_rd, by when bridge_addr has moved on: latch the
  // read address at the strobe so the word stays put, as data_unloader.sv does
  reg [6:0] bridge_rd_addr = 0;
  reg prev_bridge_rd = 0;
  always @(posedge clk_74a) begin
    prev_bridge_rd <= bridge_rd;
    if (bridge_rd && !prev_bridge_rd && bridge_addr[31:28] == SCRATCH_REGION) bridge_rd_addr <= bridge_addr[8:2];
  end
  wire bridge_scratch_wr = bridge_wr && bridge_addr[31:28] == SCRATCH_REGION;

  wire [6:0] scratch_addr = !apf_owns_scratch ? fsm_addr
      : bridge_scratch_wr ? bridge_addr[8:2] : bridge_rd_addr;
  wire scratch_we = apf_owns_scratch ? bridge_scratch_wr : fsm_we;
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
  // Byte order of the filename struct, taken from where its leading '/' lands
  reg struct_little = 0;

  function automatic [4:0] lane_shift(input [1:0] i, input little_endian);
    lane_shift = {little_endian ? i : 2'd3 - i, 3'b000};
  endfunction

  ////////////////////////////////////////////////////////////////////////////
  // Request synchronizers

  reg [2:0] track_req_s = 0;
  reg [2:0] sector_req_s = 0;
  reg [2:0] data_seek_s = 0;
  reg [2:0] pos_ack_s = 0;
  reg [2:0] copy_done_s = 0;
  reg track_req_seen = 0;
  reg sector_req_seen = 0;
  reg data_seek_seen = 0;

  always @(posedge clk_74a) begin
    track_req_s <= {track_req_s[1:0], track_req_toggle};
    sector_req_s <= {sector_req_s[1:0], sector_req_toggle};
    data_seek_s <= {data_seek_s[1:0], data_seek_req_toggle};
    pos_ack_s <= {pos_ack_s[1:0], pos_ack_toggle};
    copy_done_s <= {copy_done_s[1:0], copy_done_toggle};
    endian_s <= {endian_s[1:0], bridge_endian_little};
  end

  wire track_pending = track_req_s[2] != track_req_seen;
  wire sector_pending = sector_req_s[2] != sector_req_seen;
  wire data_seek_pending = data_seek_s[2] != data_seek_seen;

  ////////////////////////////////////////////////////////////////////////////
  // FSM

  localparam OP_PROBE = 0;
  localparam OP_TRACK = 1;
  localparam OP_SECTOR = 2;
  localparam OP_DATA = 3;  // streaming chunk
  reg [1:0] op = OP_PROBE;

  localparam CMD_READ = 0;
  localparam CMD_GETFILE = 1;
  localparam CMD_OPENFILE = 2;
  reg [1:0] cmd = CMD_READ;
  reg [2:0] cmd_err = 0;
  reg cmd_timed_out = 0;
  reg [TIMEOUT_BITS-1:0] cmd_timer = 0;
  wire cmd_ok = cmd_err == 0 && !cmd_timed_out;
  wire cmd_expired = cmd == CMD_READ ? &cmd_timer : &cmd_timer[TIMEOUT_BITS-2:0];
  reg preloading = 0;  // copying a small .msu at boot; the SNES is held in reset
  wire cmd_timeout_applies = op == OP_PROBE || preloading;

  reg prev_download = 0;
  reg probe_pending = 0;
  localparam STAGE_GETFILE = 0;
  localparam STAGE_SCAN = 1;
  localparam STAGE_OPEN = 2;
  reg [1:0] probe_stage = STAGE_GETFILE;
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

  wire [15:0] opened_slot = op == OP_PROBE || op == OP_DATA ? DATA_SLOT_ID : AUDIO_SLOT_ID;

  localparam [31:0] RING_SIZE = 32'd1 << RING_BITS;
  localparam [31:0] RING_MASK = RING_SIZE - 1'd1;

  // Streaming window: file bytes [win_start, win_end) are in SDRAM; [win_end, fetch_end) is
  // read from APF and waiting for, or in, its copy
  reg [31:0] data_size = 0;
  reg [31:0] win_start = 0;
  reg [31:0] win_end = 0;
  reg [31:0] fetch_end = 0;
  reg copy_outstanding = 0;
  reg [31:0] pend_len = 0;
  reg cur_bank = 0;  // bank the next .msu read fills
  reg [31:0] seek_target = 0;
  reg seek_waiting = 0;
  wire [31:0] stream_base = seek_waiting ? seek_target : pos_value;
  wire [31:0] stream_base_w = {stream_base[31:2], 2'b00};  // the window is word-aligned
  wire [31:0] stream_left = data_size - fetch_end;
  wire seek_restart = data_seek_addr < win_start || data_seek_addr >= fetch_end
      || fetch_end - data_seek_addr >= RING_SIZE - STREAM_GUARD;

  // core_bridge_cmd copies these when it starts the queued command; they hold until done
  assign target_dataslot_id = cmd == CMD_GETFILE ? 16'd0 : opened_slot;
  assign target_dataslot_slotoffset = read_offset;
  // .msu chunks land in bounce buffer bank cur_bank (8KB apart)
  assign target_dataslot_bridgeaddr = op == OP_SECTOR ? AUDIO_BRIDGE_ADDR
      : DATA_BRIDGE_ADDR + {cur_bank, 13'b0};
  assign target_dataslot_length = read_length;
  wire [7:0] scan_byte = fsm_q[lane_shift(idx[1:0], struct_little)+:8];
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
      stream_mode <= 0;
      stream_underrun <= 0;
      preloading <= 0;
      probe_status <= 0;
    end

    if (ioctl_download) quiet <= 0;
    else if (~&quiet) quiet <= quiet + 1'd1;

    // A chunk reached SDRAM. The other win_end writers below require !copy_outstanding
    if (copy_outstanding && copy_done_s[2] == copy_req_toggle) begin
      win_end <= win_end + pend_len;
      copy_outstanding <= 0;
    end

    case (state)
      S_IDLE: begin
        if (probe_pending && &quiet && core_running) begin
          probe_pending <= 0;
          op <= OP_PROBE;
          probe_stage <= STAGE_GETFILE;
          probe_status <= 4'd7;  // in progress
          cmd <= CMD_GETFILE;
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
        end else if (stream_mode && data_seek_pending && !(seek_restart && copy_outstanding)) begin
          // Keep the window when the seek lands inside it (bytes up to RING_SIZE -
          // STREAM_GUARD behind fetch_end are still in the ring), else restart it there once
          // the chunk being copied is in
          data_seek_seen <= data_seek_s[2];
          seek_target <= data_seek_addr;
          seek_waiting <= 1;
          if (seek_restart) begin
            win_start <= {data_seek_addr[31:2], 2'b00};
            win_end <= {data_seek_addr[31:2], 2'b00};
            fetch_end <= {data_seek_addr[31:2], 2'b00};
          end
        end else if (stream_mode && seek_waiting
            && (win_end >= seek_target + STREAM_LEAD || win_end >= data_size)) begin
          seek_waiting <= 0;
          data_seek_resp_toggle <= data_seek_seen;
        end else if (stream_mode && fetch_end < data_size) begin
          // Ask where the reader is, then decide whether to fetch the next chunk
          pos_req_toggle <= ~pos_req_toggle;
          state <= S_POS_WAIT;
        end else if (!msu_enable) begin
          // Requests while MSU is off are dropped, like hps_ext
          track_req_seen <= track_req_s[2];
          sector_req_seen <= sector_req_s[2];
          data_seek_seen <= data_seek_s[2];
        end
      end

      S_POS_WAIT: if (pos_ack_s[2] == pos_req_toggle) state <= S_FETCH;

      S_FETCH: begin
        state <= S_IDLE;
        stream_fill <= stream_base_w > win_end ? 6'd0
            : win_end - stream_base_w >= STREAM_AHEAD ? 6'd63
            : 6'((win_end - stream_base_w) >> ($clog2(STREAM_AHEAD) - 6));
        if (stream_base_w > win_end && !seek_waiting) stream_underrun <= 1;
        if (stream_base_w > fetch_end) begin
          // The reader got past everything fetched: refill from where it is, once the chunk
          // being copied is in
          if (!copy_outstanding) begin
            win_start <= stream_base_w;
            win_end <= stream_base_w;
            fetch_end <= stream_base_w;
          end
        end else if (fetch_end - stream_base_w < STREAM_AHEAD) begin  // STREAM_AHEAD < ring size
          op <= OP_DATA;
          read_offset <= fetch_end;
          read_length <= seek_waiting ? (stream_left < STREAM_LEAD ? stream_left : STREAM_LEAD)
              : (stream_left < STREAM_CHUNK ? stream_left : STREAM_CHUNK);
          drain <= 0;
          state <= S_READ;
        end
      end

      // getfile(slot 0) left the ROM path in scratch: find its end and extension
      S_GETFILE_DONE: begin
        if (!cmd_ok) begin
          state <= S_AFTER_OPEN;
        end else begin
          probe_stage <= STAGE_SCAN;
          fsm_addr <= 0;
          state <= S_DETECT_WAIT;
        end
      end

      S_DETECT_WAIT: state <= S_DETECT;

      S_DETECT: begin
        if (fsm_q[31:24] == "/") struct_little <= 0;
        else if (fsm_q[7:0] == "/") struct_little <= 1;
        else struct_little <= little;
        idx <= 0;
        have_dot <= 0;
        state <= S_SCAN_WAIT;
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
        fsm_wdata[lane_shift(idx[1:0], struct_little)+:8] <= suffix_char;
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
          if (op == OP_PROBE) probe_stage <= STAGE_OPEN;
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
          if (cmd_ok) probe_status <= 4'd1;
          else if (cmd_timed_out) probe_status <= 4'd6;
          else if (probe_stage == STAGE_GETFILE) probe_status <= 4'd2;
          else if (probe_stage == STAGE_SCAN) probe_status <= 4'd3;
          else if (cmd_err == 3'd3) probe_status <= 4'd4;  // not found
          else if (cmd_err == 3'd4) probe_status <= 4'd5;  // malformed path
          else if (cmd_err == 3'd2) probe_status <= 4'd8;  // slot undefined
          else if (cmd_err == 3'd5) probe_status <= 4'd9;  // general error
          else probe_status <= 4'd10;
          data_size <= slot_size;
          win_start <= 0;
          win_end <= 0;
          fetch_end <= 0;
          seek_waiting <= 0;
          if (cmd_ok && slot_size > DATA_MAX_SIZE) begin
            // Too big to copy: stream it on demand from the first seek
            stream_mode <= 1;
            msu_busy <= 0;
            state <= S_IDLE;
          end else if (cmd_ok && slot_size != 0) begin
            preloading <= 1;
            msu_data_download <= 1;
            state <= S_PRELOAD;
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
            cmd_return <= S_DRAIN;
            state <= S_CMD;
          end
        end
      end

      // Boot copy of a small .msu: chunk by chunk through the bounce buffer
      S_PRELOAD: begin
        if (fetch_end >= data_size) begin
          if (!copy_outstanding) begin
            preloading <= 0;
            msu_data_download <= 0;
            msu_busy <= 0;
            state <= S_IDLE;
          end
        end else begin
          op <= OP_DATA;
          read_offset <= fetch_end;
          read_length <= stream_left < STREAM_CHUNK ? stream_left : STREAM_CHUNK;
          drain <= 0;
          state <= S_READ;
        end
      end

      S_DRAIN: begin
        // The bridge receiver and the clk_sys write path empty well within this
        drain <= drain + 1'd1;
        if (&drain) begin
          audio_download <= 0;
          if (op == OP_DATA && preloading && cmd_timed_out) begin
            // APF stopped answering during the boot copy: give up and let the game run
            preloading <= 0;
            msu_data_download <= 0;
            msu_busy <= 0;
            state <= S_IDLE;
          end else if (op == OP_DATA) state <= S_COPY_WAIT;
          else state <= S_IDLE;
        end
      end

      // Hand the chunk to the copy engine once it has finished the previous one, and fill
      // the other bank meanwhile
      S_COPY_WAIT: begin
        if (!copy_outstanding) begin
          copy_bank <= cur_bank;
          copy_base <= read_offset;
          copy_len <= read_length[13:0];
          copy_req_toggle <= ~copy_req_toggle;
          copy_outstanding <= 1;
          pend_len <= read_length;
          fetch_end <= fetch_end + read_length;
          cur_bank <= ~cur_bank;
          state <= preloading ? S_PRELOAD : S_IDLE;
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
        else if (cmd_timeout_applies && cmd_expired) begin
          cmd_timed_out <= 1;
          state <= cmd_return;
        end
      end

      S_CMD_WAIT_HIGH: begin
        cmd_timer <= cmd_timer + 1'd1;
        if (target_dataslot_done) begin
          cmd_err <= target_dataslot_err;
          state <= cmd_return;
        end else if (cmd_timeout_applies && cmd_expired) begin
          cmd_timed_out <= 1;
          state <= cmd_return;
        end
      end

      default: state <= S_IDLE;
    endcase
  end

endmodule

// Bridge writes to region 0x4 (.msu data and .pcm sectors) handed to clk_sys one 32-bit word
// at a time. APF writes at most every ~75 clk_74a cycles, so a toggle handshake replaces
// data_loader's dual-clock FIFO; the word and address are held until the next write.
module msu_bridge_rx #(
    parameter [3:0] REGION = 4'h4
) (
    input wire clk_74a,
    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire bridge_wr,
    input wire [31:0] bridge_wr_data,

    input wire clk_sys,
    output reg rx_valid = 0,  // one clk_sys pulse per word
    output reg [27:0] rx_addr = 0,
    output reg [31:0] rx_data = 0  // file byte n at [8n+7:8n], as data_loader unpacks it
);
  reg prev_wr = 0;
  reg toggle = 0;
  reg [27:0] held_addr = 0;
  reg [31:0] held_data = 0;

  always @(posedge clk_74a) begin
    prev_wr <= bridge_wr;
    if (bridge_wr && !prev_wr && bridge_addr[31:28] == REGION) begin
      held_addr <= bridge_addr[27:0];
      held_data <= bridge_endian_little ? bridge_wr_data : {
        bridge_wr_data[7:0], bridge_wr_data[15:8], bridge_wr_data[23:16], bridge_wr_data[31:24]
      };
      toggle <= ~toggle;
    end
  end

  reg [2:0] toggle_s = 0;
  always @(posedge clk_sys) begin
    toggle_s <= {toggle_s[1:0], toggle};
    rx_valid <= toggle_s[2] != toggle_s[1];
    if (toggle_s[2] != toggle_s[1]) begin
      rx_addr <= held_addr;
      rx_data <= held_data;
    end
  end
endmodule
