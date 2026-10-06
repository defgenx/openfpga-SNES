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
    // SDRAM banks 2-3 hold 2^RING_BITS bytes of the .msu file. A file up to DATA_MAX_SIZE is
    // copied whole at boot; a larger one is streamed through them as a ring (file byte X at
    // X mod 2^RING_BITS), see docs/MSU-1.md "Streaming"
    parameter RING_BITS = 23,
    parameter [31:0] DATA_MAX_SIZE = 32'h0080_0000,
    // Games time a seek out (Super Road Blaster: "Timeout while seeking"), so a seek completes
    // once STREAM_LEAD bytes past it are in, fetched as one read; chunks stay small so one
    // already in flight delays a seek only briefly
    parameter [31:0] STREAM_CHUNK = 32'h0000_2000,  // bytes per .msu read; at most the bounce buffer
    parameter [31:0] STREAM_LEAD = 32'h0000_1000,  // buffered past a seek before it completes
    parameter [31:0] STREAM_GUARD = 32'h0010_0000,  // ring space kept free behind the reader
    // Read-ahead past the reader. Fetching only this far keeps SDRAM writes near the game's
    // read rate, so they rarely compete with its reads
    parameter [31:0] STREAM_AHEAD = 32'h0004_0000,  // must stay below RING_SIZE/2 - STREAM_GUARD
    // Quiet time after the last ROM/save load before probing (2^20 cycles ~ 14ms)
    parameter QUIET_BITS = 20,
    // Give up on an unanswered target command during the boot probe: Get/Open File after
    // 2^29 cycles (~7s), the .msu copy (up to 8MB, several seconds) after 2^30 (~14s)
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

    // Every .msu read lands in one of two banks of msu_sdram_store's bounce buffer, which
    // copies each word to SDRAM as soon as it lands. Per bank: a request before the read
    // (with copy_base/copy_len, latched by the store), fill done after it, and copy done once
    // the chunk is in SDRAM; a bank is reused only after its copy is done
    output reg [1:0] copy_req_toggle = 0,
    output reg copy_audio = 0,  // the chunk is .pcm data for the audio ring
    output wire copy_region,  // streaming: SDRAM region of the window the chunk belongs to
    output wire seek_region,  // streaming: SDRAM region the reader is in after a seek
    output wire [31:0] copy_base,  // the chunk's read_offset/read_length, stable for the read
    output wire [13:0] copy_len,
    output reg [1:0] fill_done_toggle = 0,
    input wire [1:0] copy_done_toggle,
    // Audio sectors are played from the SDRAM audio ring (msu_sdram_store replays them);
    // the payload is stable until the done toggle
    output reg replay_req_toggle = 0,
    output wire [9:0] replay_slot,
    output wire [10:0] replay_len,
    input wire replay_done_toggle,
    input wire data_seek_req_toggle,
    input wire [31:0] data_seek_addr,
    output reg data_seek_resp_toggle = 0,
    output reg pos_req_toggle = 0,
    input wire pos_ack_toggle,
    input wire [31:0] pos_value,
    input wire pos_seeking  // pos_value was taken while a seek was in flight: not the reader's
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
  localparam S_PRELOAD = 24;
  localparam S_FETCH_CHECK = 25;
  localparam S_FETCH_GO = 26;
  localparam S_SETTLE = 27;
  localparam S_AUD_ISSUE = 28;

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
  reg [2:0] copy_done0_s = 0;
  reg [2:0] copy_done1_s = 0;
  reg [2:0] replay_done_s = 0;
  reg track_req_seen = 0;
  reg sector_req_seen = 0;
  reg data_seek_seen = 0;

  always @(posedge clk_74a) begin
    track_req_s <= {track_req_s[1:0], track_req_toggle};
    sector_req_s <= {sector_req_s[1:0], sector_req_toggle};
    data_seek_s <= {data_seek_s[1:0], data_seek_req_toggle};
    pos_ack_s <= {pos_ack_s[1:0], pos_ack_toggle};
    copy_done0_s <= {copy_done0_s[1:0], copy_done_toggle[0]};
    copy_done1_s <= {copy_done1_s[1:0], copy_done_toggle[1]};
    replay_done_s <= {replay_done_s[1:0], replay_done_toggle};
    endian_s <= {endian_s[1:0], bridge_endian_little};
  end

  wire track_pending = track_req_s[2] != track_req_seen;
  wire sector_pending = sector_req_s[2] != sector_req_seen;
  wire data_seek_pending = data_seek_s[2] != data_seek_seen;

  ////////////////////////////////////////////////////////////////////////////
  // FSM

  localparam OP_PROBE = 0;
  localparam OP_TRACK = 1;
  localparam OP_DATA = 3;  // .msu chunk
  localparam OP_AUDIO = 4;  // .pcm chunk into the audio ring
  reg [2:0] op = OP_PROBE;

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

  reg [21:0] read_page;  // reads start on a 1KB page: .pcm and .msu chunks alike
  reg [13:0] read_length;  // chunks are at most 8KB
  wire [31:0] read_offset = {read_page, 10'b0};
  reg [9:0] drain;

  wire [15:0] opened_slot = op == OP_PROBE || op == OP_DATA ? DATA_SLOT_ID : AUDIO_SLOT_ID;

  // Audio ring: SDRAM holds .pcm sectors [aud_start, aud_end) of the current track at slot
  // sector mod 1024, with [aud_end, aud_fetch) being read and copied. APF caches file fragments
  // for the last-accessed slot only, and finding a position in a large .msu again after a .pcm
  // read costs tens of ms, so the track is read ahead in bursts: from under AUD_LOW sectors
  // ahead of msu_audio's request up to AUD_HIGH, 8KB per read; .msu work waits meanwhile
  // unless a seek needs data. See docs/MSU-1.md "Audio ring".
  // Sector numbers are AW bits: tracks up to 256MB (~25 minutes)
  localparam AW = 18;
  localparam [AW-1:0] AUD_LOW = 176;  // ~1s of 44.1kHz stereo
  localparam [AW-1:0] AUD_HIGH = 352;
  localparam [AW-1:0] AUD_KEEP = 1016;  // ring slots in use at most
  reg [AW-1:0] aud_start = 0, aud_end = 0, aud_fetch = 0;
  reg aud_bursting = 0;
  reg [1:0] pend_audio = 0;  // per bank: the chunk is audio
  localparam RP_IDLE = 0;
  localparam RP_LEAD = 1;
  localparam RP_WAIT = 2;
  localparam RP_TAIL = 3;
  reg [1:0] rp_state = RP_IDLE;
  reg [9:0] rp_drain = 0;
  assign replay_slot = sector_num[9:0];
  assign replay_len = sector_length;

  localparam [31:0] RING_SIZE = 32'd1 << RING_BITS;

  // Streaming: two windows in their own halves of the SDRAM ring (regions). The active one
  // holds file bytes [win_start, win_end) in SDRAM, with [win_end, fetch_end) read from APF
  // and being copied, and is read ahead. The parked one keeps [park_start, park_end) from
  // the last window the game left: Super Road Blaster alternates between a chapter's frame
  // table and frame data every frame, so both stay buffered.
  // .msu offsets are 30 bits: files up to 1GB, MiSTer's limit too. Windows are kept in 1KB
  // pages (PW bits); data_pages rounds the file up, data_size_lo gives the last read's length
  localparam OB = 30;
  localparam PW = OB - 10;
  localparam [31:0] REGION_PAGES = RING_SIZE >> 11;
  localparam [31:0] GUARD_PAGES = STREAM_GUARD >> 10;
  localparam [31:0] AHEAD_PAGES = STREAM_AHEAD >> 10;
  localparam [31:0] CHUNK_PAGES = STREAM_CHUNK >> 10;
  // The window starts on the seek's page, so one more page keeps STREAM_LEAD past the seek
  localparam [31:0] LEAD_PAGES = (STREAM_LEAD >> 10) + 1;
  reg [PW-1:0] data_pages = 0;
  reg [13:0] data_size_lo = 0;
  reg [PW-1:0] win_start = 0;
  reg [PW-1:0] win_end = 0;
  reg [PW-1:0] fetch_end = 0;
  reg [PW-1:0] park_start = 0;
  reg [PW-1:0] park_end = 0;  // empty when equal to park_start
  reg act_region = 0;
  reg [1:0] copy_outstanding = 0;  // per bank: read issued, chunk not yet in SDRAM
  reg [3:0] pend_pages0 = 0;
  reg [3:0] pend_pages1 = 0;
  reg cur_bank = 0;  // bank the next .msu read fills
  reg done_bank = 0;  // bank whose copy completes next (chunks complete in order)
  wire any_outstanding = |copy_outstanding;
  wire bank_free = !copy_outstanding[cur_bank];
  wire done_bank_copied = done_bank ? copy_done1_s[2] == copy_req_toggle[1]
      : copy_done0_s[2] == copy_req_toggle[0];
  reg [PW-1:0] seek_target = 0;
  reg seek_waiting = 0;
  wire [PW-1:0] stream_base_c = seek_waiting ? seek_target : pos_value[OB-1:10];
  wire [PW-1:0] stream_left = data_pages - fetch_end;
  wire [PW-1:0] seek_addr = data_seek_addr[OB-1:10];
  // Seeks get a short read so they complete quickly; read-ahead and the boot copy use chunks
  wire [3:0] chunk_limit = seek_waiting && !preloading ? LEAD_PAGES[3:0] : CHUNK_PAGES[3:0];
  wire last_chunk = stream_left <= chunk_limit;
  wire [3:0] chunk_pages_c = last_chunk ? stream_left[3:0] : chunk_limit;
  // The last read stops at the file's end; it is under 16KB, so 14 bits of the difference do
  wire [13:0] chunk_length_c = last_chunk ? data_size_lo - {fetch_end[3:0], 10'b0} : {chunk_limit, 10'b0};
  assign copy_base = read_offset;
  assign copy_len = read_length;
  // Pages up to REGION_PAGES - GUARD_PAGES behind a window's end are still in its region
  wire seek_restart_c = seek_addr < win_start || seek_addr >= fetch_end
      || fetch_end - seek_addr >= REGION_PAGES - GUARD_PAGES;
  wire seek_in_parked_c = seek_addr >= park_start && seek_addr < park_end
      && park_end - seek_addr < REGION_PAGES - GUARD_PAGES;

  // The comparisons above are registered so they stay off the 74MHz FSM paths. The FSM acts
  // on them only once state has held a cycle (settled), so they reflect its last writes; the
  // concurrent win_end advance only grows win_end, which can delay seek_done by a cycle.
  reg [PW-1:0] stream_base = 0;
  reg [3:0] chunk_pages = 0;
  reg [13:0] chunk_length = 0;
  reg seek_restart = 0, seek_in_parked = 0, seek_done = 0, more_to_fetch = 0;
  reg past_fetch = 0, ahead_ok = 0, behind_win = 0;
  reg [5:0] fill_c = 0;
  reg [4:0] prev_state = 0;
  wire settled = prev_state == state;
  // APF caches file fragments for the last-accessed slot only, and re-finding a position in a
  // large .msu after a .pcm read costs tens of ms. During an audio refill burst, .msu reads
  // wait for the next sector request, up to 2^17 cycles (~1.8ms) after the last sector
  wire [AW-1:0] aud_sector = sector_num[AW-1:0];
  wire [AW-1:0] aud_last = track_size[AW+9:10] + (|track_size[9:0]);  // sectors in the track
  wire [AW-1:0] aud_left = aud_last - aud_fetch;
  wire aud_last_chunk = aud_left <= 8;
  // aud_near: in the window or in the next chunk to read (from aud_fetch)
  reg aud_hit = 0, aud_near = 0, aud_more = 0, aud_low = 0, aud_high = 0, aud_full = 0;
  reg [3:0] aud_chunk_pages = 0;
  reg [13:0] aud_chunk_length = 0;
  always @(posedge clk_74a) begin
    aud_hit <= aud_sector >= aud_start && aud_sector < aud_end;
    aud_near <= aud_sector >= aud_start && aud_sector <= aud_fetch;
    aud_more <= aud_fetch < aud_last;
    aud_low <= aud_fetch - aud_sector < AUD_LOW;
    aud_high <= aud_fetch - aud_sector >= AUD_HIGH;
    aud_full <= aud_fetch + 8 - aud_start > AUD_KEEP;
    aud_chunk_pages <= aud_last_chunk ? aud_left[3:0] : 4'd8;
    aud_chunk_length <= aud_last_chunk ? track_size[13:0] - {aud_fetch[3:0], 10'b0} : 14'h2000;
  end
  always @(posedge clk_74a) begin
    prev_state <= state;
    stream_base <= stream_base_c;
    chunk_pages <= chunk_pages_c;
    chunk_length <= chunk_length_c;
    seek_restart <= seek_restart_c;
    seek_in_parked <= seek_in_parked_c;
    seek_done <= win_end >= seek_target + LEAD_PAGES[PW-1:0] || win_end >= data_pages;
    more_to_fetch <= fetch_end < data_pages;
    past_fetch <= stream_base_c > fetch_end;
    ahead_ok <= fetch_end - stream_base_c < AHEAD_PAGES;  // < ring size
    behind_win <= stream_base_c > win_end;
    fill_c <= stream_base_c > win_end ? 6'd0
        : win_end - stream_base_c >= AHEAD_PAGES ? 6'd63
        : 6'((win_end - stream_base_c) >> ($clog2(AHEAD_PAGES) - 6));
  end

  assign copy_region = act_region;
  assign seek_region = act_region;

  // core_bridge_cmd copies these when it starts the queued command; they hold until done
  assign target_dataslot_id = cmd == CMD_GETFILE ? 16'd0 : opened_slot;
  assign target_dataslot_slotoffset = read_offset;
  // .msu chunks land in bounce buffer bank cur_bank (8KB apart)
  assign target_dataslot_bridgeaddr = DATA_BRIDGE_ADDR + {cur_bank, 13'b0};
  assign target_dataslot_length = read_length;
  wire [7:0] scan_byte = fsm_q[lane_shift(idx[1:0], struct_little)+:8];
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

    if (aud_low && aud_more) aud_bursting <= 1;
    else if (aud_high || !aud_more) aud_bursting <= 0;

    if (ioctl_download) quiet <= 0;
    else if (~&quiet) quiet <= quiet + 1'd1;

    // A chunk reached SDRAM. The other win_end writers below require !any_outstanding
    if (copy_outstanding[done_bank] && done_bank_copied) begin
      if (pend_audio[done_bank]) aud_end <= aud_end + (done_bank ? pend_pages1 : pend_pages0);
      else win_end <= win_end + (done_bank ? pend_pages1 : pend_pages0);
      copy_outstanding[done_bank] <= 0;
      done_bank <= ~done_bank;
    end

    // Replays run beside the FSM, so a sector in the audio ring reaches msu_audio (4KB FIFO,
    // ~23ms) even while an APF read is in flight. audio_download is up around the words, as for
    // a hps_ext transfer
    case (rp_state)
      RP_IDLE: if (msu_enable && sector_pending && aud_hit) begin
        sector_req_seen <= sector_req_s[2];
        audio_download <= 1;
        rp_drain <= 0;
        rp_state <= RP_LEAD;
      end
      RP_LEAD: begin
        rp_drain <= rp_drain + 1'd1;
        if (rp_drain == 10'd31) begin
          replay_req_toggle <= ~replay_req_toggle;
          rp_state <= RP_WAIT;
        end
      end
      RP_WAIT: if (replay_done_s[2] == replay_req_toggle) begin
        rp_drain <= 0;
        rp_state <= RP_TAIL;
      end
      default: begin  // RP_TAIL: let msu_audio take the last words before the download ends
        rp_drain <= rp_drain + 1'd1;
        if (&rp_drain) begin
          audio_download <= 0;
          rp_state <= RP_IDLE;
        end
      end
    endcase

    case (state)
      S_IDLE: if (settled) begin
        if (probe_pending && &quiet && core_running) begin
          probe_pending <= 0;
          op <= OP_PROBE;
          probe_stage <= STAGE_GETFILE;
          probe_status <= 4'd7;  // in progress
          cmd <= CMD_GETFILE;
          cmd_return <= S_GETFILE_DONE;
          state <= S_CMD;
        end else if (msu_enable && track_pending && !any_outstanding) begin
          track_req_seen <= track_req_s[2];
          op <= OP_TRACK;
          digit_value <= track_num;
          digit_pos <= 0;
          digit <= 0;
          ndigits <= 0;
          state <= S_DIGITS;
        end else if (msu_enable && sector_pending && !aud_hit && !aud_near && !any_outstanding) begin
          // Outside the ring (track start, a loop point or resume beyond it): restart there
          aud_start <= aud_sector;
          aud_end <= aud_sector;
          aud_fetch <= aud_sector;
          state <= S_SETTLE;
        end else if (stream_mode && data_seek_pending && !(seek_restart && any_outstanding)) begin
          // Inside the active window: keep it. Inside the parked one: swap them. Elsewhere:
          // park the active window and start a new one at the seek, in the other region.
          // Switching waits for the chunks being copied, which belong to the active window.
          data_seek_seen <= data_seek_s[2];
          seek_target <= seek_addr;
          seek_waiting <= 1;
          if (seek_restart) begin
            park_start <= win_start;
            park_end <= win_end;
            act_region <= ~act_region;
            if (seek_in_parked) begin
              win_start <= park_start;
              win_end <= park_end;
              fetch_end <= park_end;
            end else begin
              win_start <= seek_addr;
              win_end <= seek_addr;
              fetch_end <= seek_addr;
            end
          end
          state <= S_SETTLE;
        end else if (stream_mode && seek_waiting && seek_done) begin
          seek_waiting <= 0;
          data_seek_resp_toggle <= data_seek_seen;
          state <= S_SETTLE;
        end else if (msu_enable && sector_pending && !aud_hit && aud_near && aud_more && bank_free) begin
          // msu_audio is waiting for a sector being read: keep reading the track
          state <= S_AUD_ISSUE;
        end else if (stream_mode && bank_free && more_to_fetch
            && (seek_waiting || !(aud_bursting && aud_more))) begin
          // Ask where the reader is, then decide whether to fetch the next chunk
          pos_req_toggle <= ~pos_req_toggle;
          state <= S_POS_WAIT;
        end else if (msu_enable && aud_bursting && aud_more && bank_free) begin
          state <= S_AUD_ISSUE;
        end else if (!msu_enable) begin
          // Requests while MSU is off are dropped, like hps_ext
          track_req_seen <= track_req_s[2];
          sector_req_seen <= sector_req_s[2];
          data_seek_seen <= data_seek_s[2];
        end
      end

      S_SETTLE: state <= S_IDLE;

      // Read the next .pcm chunk at aud_fetch into bank cur_bank, for the audio ring
      S_AUD_ISSUE: begin
        op <= OP_AUDIO;
        read_page <= 22'(aud_fetch);
        read_length <= aud_chunk_length;
        copy_audio <= 1;
        copy_req_toggle[cur_bank] <= ~copy_req_toggle[cur_bank];
        copy_outstanding[cur_bank] <= 1;
        pend_audio[cur_bank] <= 1;
        if (cur_bank) pend_pages1 <= aud_chunk_pages;
        else pend_pages0 <= aud_chunk_pages;
        if (aud_full) aud_start <= aud_fetch + 8 - AUD_KEEP;
        drain <= 0;
        state <= S_READ;
      end

      S_POS_WAIT: if (pos_ack_s[2] == pos_req_toggle) state <= S_FETCH_CHECK;

      // A position taken during a seek says nothing about the active window; the seek itself
      // is handled from S_IDLE
      S_FETCH_CHECK: state <= pos_seeking && !seek_waiting ? S_IDLE : S_FETCH_GO;

      S_FETCH_GO: begin
        state <= S_IDLE;
        stream_fill <= fill_c;
        if (behind_win && !seek_waiting) stream_underrun <= 1;
        if (past_fetch) begin
          // The reader got past everything fetched: refill from where it is, once the chunk
          // being copied is in
          if (!any_outstanding) begin
            win_start <= stream_base;
            win_end <= stream_base;
            fetch_end <= stream_base;
          end
        end else if (ahead_ok && bank_free) begin
          op <= OP_DATA;
          read_page <= fetch_end;
          read_length <= chunk_length;
          copy_audio <= 0;
          copy_req_toggle[cur_bank] <= ~copy_req_toggle[cur_bank];
          copy_outstanding[cur_bank] <= 1;
          pend_audio[cur_bank] <= 0;
          if (cur_bank) pend_pages1 <= chunk_pages;
          else pend_pages0 <= chunk_pages;
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
          data_pages <= slot_size[31:OB] != 0 || &slot_size[OB-1:10] ? {PW{1'b1}}
              : slot_size[OB-1:10] + (|slot_size[9:0]);
          data_size_lo <= slot_size[31:OB] != 0 || &slot_size[OB-1:10] ? 14'h3C00 : slot_size[13:0];
          win_start <= 0;
          win_end <= 0;
          fetch_end <= 0;
          seek_waiting <= 0;
          park_start <= 0;
          park_end <= 0;
          act_region <= 0;
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
          // A new track: nothing of it is in the audio ring yet (no chunk is outstanding)
          aud_start <= 0;
          aud_end <= 0;
          aud_fetch <= 0;
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
        if (!settled) begin
          // chunk_* and more_to_fetch catch up with S_DRAIN's fetch_end
        end else if (!more_to_fetch) begin
          if (!any_outstanding) begin
            preloading <= 0;
            msu_data_download <= 0;
            msu_busy <= 0;
            state <= S_IDLE;
          end
        end else if (bank_free) begin
          op <= OP_DATA;
          read_page <= fetch_end;
          read_length <= chunk_length;
          copy_audio <= 0;
          copy_req_toggle[cur_bank] <= ~copy_req_toggle[cur_bank];
          copy_outstanding[cur_bank] <= 1;
          pend_audio[cur_bank] <= 0;
          if (cur_bank) pend_pages1 <= chunk_pages;
          else pend_pages0 <= chunk_pages;
          drain <= 0;
          state <= S_READ;
        end
      end

      S_DRAIN: begin
        // The bridge receiver and the clk_sys write path empty well within this
        drain <= drain + 1'd1;
        if (&drain) begin
          if (op == OP_DATA && preloading && cmd_timed_out) begin
            // APF stopped answering during the boot copy: give up and let the game run
            preloading <= 0;
            msu_data_download <= 0;
            msu_busy <= 0;
            state <= S_IDLE;
          end else if (op == OP_DATA || op == OP_AUDIO) begin
            // The bank is filled; its copy finishes on its own, so move to the other bank
            fill_done_toggle[cur_bank] <= ~fill_done_toggle[cur_bank];
            if (op == OP_DATA) fetch_end <= fetch_end + (cur_bank ? pend_pages1 : pend_pages0);
            else aud_fetch <= aud_fetch + (cur_bank ? pend_pages1 : pend_pages0);
            cur_bank <= ~cur_bank;
            state <= preloading ? S_PRELOAD : S_IDLE;
          end else state <= S_IDLE;
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

// Bridge writes to region 0x4 (.msu and .pcm chunks for the bounce buffer) handed to clk_sys one 32-bit word
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
    output reg [13:0] rx_addr = 0,  // {bank, byte offset in the chunk}
    output reg [31:0] rx_data = 0  // file byte n at [8n+7:8n], as data_loader unpacks it
);
  reg prev_wr = 0;
  reg toggle = 0;
  reg [13:0] held_addr = 0;
  reg [31:0] held_data = 0;

  always @(posedge clk_74a) begin
    prev_wr <= bridge_wr;
    if (bridge_wr && !prev_wr && bridge_addr[31:28] == REGION) begin
      held_addr <= bridge_addr[13:0];
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
