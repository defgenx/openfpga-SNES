// clk_sys half of MSU-1 on the Pocket. See docs/MSU-1.md.
//
// msu_host replaces upstream hps_ext.v: same mounting/missing/ack behaviour, but the
// requests go to target/pocket/msu_apf.sv (clk_74a) as toggles instead of to the HPS. Sector
// data reaches msu_audio from msu_sdram_store's audio ring replay.
module msu_host (
    input wire clk_sys,
    input wire reset,

    // From MSU.sv / msu_audio.v
    input wire [15:0] msu_track_num,
    input wire msu_track_request,
    input wire msu_audio_req,
    input wire msu_audio_seek,
    input wire [21:0] msu_audio_sector,
    input wire msu_audio_download,  // already synchronized to clk_sys

    output reg msu_track_mounting = 0,
    output reg msu_track_missing = 0,
    output reg [31:0] msu_audio_size = 0,
    output reg msu_audio_ack = 0,

    // To/from msu_apf; payloads stay stable until the next toggle
    output reg track_req_toggle = 0,
    output reg [15:0] track_num = 0,
    input wire track_resp_toggle,
    input wire [31:0] track_size,
    output reg sector_req_toggle = 0,
    output reg [21:0] sector_num = 0
);
  reg [2:0] track_resp_s = 0;
  reg track_resp_seen = 0;

  reg old_req = 0;
  reg old_seek = 0;
  reg old_track_request = 0;
  reg old_download = 0;

  always @(posedge clk_sys) begin
    track_resp_s <= {track_resp_s[1:0], track_resp_toggle};

    old_download <= msu_audio_download;
    if (!msu_audio_download && old_download) msu_audio_ack <= 0;
    if (msu_audio_download && !old_download) msu_audio_ack <= 1;

    // A sector request while a track is opening is dropped, as in hps_ext
    old_req <= msu_audio_req;
    old_seek <= msu_audio_seek;
    if (!msu_track_request && ((!old_req && msu_audio_req) || (!old_seek && msu_audio_seek))) begin
      sector_num <= msu_audio_sector;
      sector_req_toggle <= ~sector_req_toggle;
    end

    old_track_request <= msu_track_request;
    if (!old_track_request && msu_track_request) begin
      track_num <= msu_track_num;
      track_req_toggle <= ~track_req_toggle;
      msu_track_missing <= 0;
      msu_track_mounting <= 1;
    end

    if (track_resp_s[2] != track_resp_seen) begin
      track_resp_seen <= track_resp_s[2];
      msu_audio_size <= track_size;
      msu_track_missing <= track_size == 0;
      msu_track_mounting <= 0;
      msu_audio_ack <= 0;
    end

    if (reset) begin
      msu_track_missing <= 0;
      msu_track_mounting <= 0;
      msu_audio_ack <= 0;
    end
  end
endmodule

// The .msu data file in SDRAM banks 2-3 (8MB ring, then the 1MB audio ring), reached through the controller's SNI
// port, which waits for idle slots and so never disturbs ROM timing on port 0.
// Replaces upstream msu_data_store.sv (DDR3) for the MSU.sv data interface. msu_apf reads the
// file a chunk at a time into one of two block RAM bounce buffer banks; this copies each word
// into SDRAM as soon as it lands, between the game's reads. While streaming, the SDRAM banks
// are a ring around the reader. See docs/MSU-1.md.
module msu_sdram_store #(
    parameter RING_BITS = 23,  // .msu ring; the 1MB audio ring sits above it (AUD_WORD_BASE)
    parameter CHUNK_WORD_BITS = 11  // two bounce buffer banks of 2^n 32-bit words (8KB each)
) (
    input wire clk_sys,

    // Streaming: seeks wait for msu_apf to buffer data; it polls the read position
    input wire stream_mode,  // already synchronized to clk_sys
    output reg seek_req_toggle = 0,
    output reg [31:0] seek_addr = 0,
    input wire seek_resp_toggle,
    input wire pos_req_toggle,
    output reg pos_ack_toggle = 0,
    output reg [31:0] pos_value = 0,
    output reg pos_seeking = 0,  // pos_value was taken while a seek was in flight
    // A streaming seek slower than STALL_AFTER freezes the SNES until it completes (or until
    // STALL_MAX), so the game cannot time it out. seek_slowest: longest seek so far, for the
    // debug overlay: 0 none, 1 under 10ms, 2 under 30ms, 3 longer
    output wire stall,
    output reg [1:0] seek_slowest = 0,

    // Bounce buffer: chunk words from msu_bridge_rx, addressed {bank, byte offset in chunk}
    input wire msu_data_download,  // boot copy in progress: the SNES is in reset
    input wire load_valid,
    input wire [CHUNK_WORD_BITS+2:0] load_addr,
    input wire [31:0] load_data,
    // Per bank: a request (latching copy_base/copy_len) before its chunk arrives, fill done
    // once it has all arrived, and copy done once it is all in SDRAM
    input wire [1:0] copy_req_toggle,
    input wire copy_region,  // streaming: ring region the requested chunk goes to
    input wire copy_audio,  // the chunk is .pcm data for the audio ring (copy_base: byte in file)
    input wire seek_region,  // streaming: ring region of the reader, valid with the seek response
    input wire [31:0] copy_base,
    input wire [CHUNK_WORD_BITS+2:0] copy_len,
    input wire [1:0] fill_done_toggle,
    output reg [1:0] copy_done_toggle = 0,

    // Audio ring replay: one .pcm sector (replay_len bytes from ring slot replay_slot) as
    // msu_audio's 16-bit writes; the request payload is stable until the done toggle
    input wire replay_req_toggle,
    input wire [9:0] replay_slot,
    input wire [10:0] replay_len,
    output reg replay_done_toggle = 0,
    output reg replay_wr = 0,
    output reg [15:0] replay_data = 0,

    // MSU.sv data port
    input wire [31:0] rd_addr,
    input wire rd_seek,
    output reg rd_seek_done = 0,
    output wire [7:0] rd_dout,

    // sdram SNI port
    output reg [24:0] sni_addr = 0,
    output reg [15:0] sni_din = 0,
    input wire [15:0] sni_dout,
    output reg sni_wr_req = 0,
    output reg sni_rd_req = 0,
    input wire sni_ready
);
  // Word addresses wrap at the ring size
  // Streaming splits the ring into two regions, one per msu_apf window
  localparam [22:0] WORD_MASK = (23'd1 << (RING_BITS - 1)) - 1'd1;
  localparam [22:0] REGION_WORD_MASK = WORD_MASK >> 1;
  function automatic [22:0] wrap_in(input region, input [22:0] w);
    wrap_in = stream_mode ? (w & REGION_WORD_MASK) | ({22'd0, region} << (RING_BITS - 2))
        : w & WORD_MASK;
  endfunction
  // Audio ring: 1MB (1024 .pcm sectors) at SNI word 0x400000, above the .msu ring
  localparam [22:0] AUD_WORD_BASE = 23'h400000;
  localparam [22:0] AUD_WORD_MASK = 23'h07FFFF;
  reg read_region = 0;
  function automatic [22:0] wrap(input [22:0] w);
    wrap = wrap_in(read_region, w);
  endfunction

  // Bounce buffer: APF fills a bank at bridge speed, the copy drains it at SNI speed. A bank
  // is refilled only after its copy is done, so nothing is ever dropped.
  reg [31:0] cbuf[0:(2<<CHUNK_WORD_BITS)-1];
  reg [31:0] cbuf_q = 0;

  wire load_bank = load_addr[CHUNK_WORD_BITS+2];
  always @(posedge clk_sys) begin
    if (load_valid) cbuf[load_addr[CHUNK_WORD_BITS+2:2]] <= load_data;
    cbuf_q <= cbuf[{eng_bank, copy_idx}];
  end

  // Per bank: chunk to copy, words arrived so far (APF writes them in order), fill complete
  reg [2:0] req0_s = 0, req1_s = 0, fill0_s = 0, fill1_s = 0;
  reg [1:0] req_seen = 0;
  reg [1:0] fill_seen = 0;
  reg [1:0] pending = 0;
  reg [1:0] filled = 0;
  reg [23:0] base0 = 0, base1 = 0;  // the ring only uses the low 24 bits of the file offset
  // Streaming: file offset where each region's buffered data ends, from the chunks copied
  // into it; the reader is frozen before it gets there (see stall)
  reg [29:0] fbase0 = 0, fbase1 = 0, copy_cur_fbase = 0;
  reg [29:0] avail_end0 = 0, avail_end1 = 0;
  wire [29:0] avail_end = read_region ? avail_end1 : avail_end0;
  reg region0 = 0, region1 = 0;
  reg audio0 = 0, audio1 = 0;
  reg copy_cur_region = 0;
  reg copy_cur_audio = 0;
  reg [CHUNK_WORD_BITS+2:0] len0 = 0, len1 = 0;
  reg [CHUNK_WORD_BITS:0] arrived0 = 0, arrived1 = 0;
  // Delayed a cycle: a word counted here is readable through cbuf_q
  reg [CHUNK_WORD_BITS:0] arrived0_d = 0, arrived1_d = 0;
  reg [1:0] filled_d = 0;

  reg eng_bank = 0;  // banks are copied alternately, in the order they are filled
  reg copying = 0;
  reg [23:0] copy_cur_base = 0;
  reg [CHUNK_WORD_BITS-1:0] copy_idx = 0;
  reg [CHUNK_WORD_BITS:0] copy_left = 0;  // 32-bit words still to copy
  reg copy_half = 0;  // 1 once the low half of copy_idx is written
  reg copy_q_ok = 0;  // cbuf_q holds copy_idx

  wire [CHUNK_WORD_BITS:0] eng_arrived_d = eng_bank ? arrived1_d : arrived0_d;
  wire copy_word_ready = filled_d[eng_bank] || {1'b0, copy_idx} < eng_arrived_d;


  reg [2:0] seek_resp_s = 0;
  reg [2:0] pos_req_s = 0;
  reg stream_seek_wait = 0;
  reg last_was_read = 0;
  // clk_sys is ~21.3MHz: 20ms (the game allows ~30ms per seek), 10ms, 30ms, and a 1.5s cap
  localparam [25:0] STALL_AFTER = 26'd426_000;
  localparam [25:0] SLOW_10MS = 26'd213_000;
  localparam [25:0] SLOW_30MS = 26'd640_000;
  localparam [25:0] STALL_MAX = 26'd32_000_000;
  reg [25:0] seek_timer = 0;
  // Sequential reads: freeze before the reader passes the buffered data (avail_end), once the
  // first streaming seek has set up a window. The word after the reader's must be in SDRAM
  // too, as the prefetch reads it; MSU.sv only moves rd_addr with rd_seek, which gates this
  reg stream_armed = 0;
  reg seek_active = 0;
  reg seek_pending = 0;
  wire starving = stream_mode && stream_armed && !msu_data_download && !rd_seek && !seek_pending
      && !seek_active && !stream_seek_wait && rd_addr[29:0] + 30'd4 > avail_end;
  reg [25:0] starve_timer = 0;
  assign stall = stream_seek_wait && seek_timer >= STALL_AFTER && seek_timer < STALL_MAX
      || starving && starve_timer < STALL_MAX;
  always @(posedge clk_sys) begin
    if (!stream_mode) stream_armed <= 0;
    else if (stream_seek_wait && seek_resp_s[2] == seek_req_toggle) stream_armed <= 1;
    if (!starving) starve_timer <= 0;
    else if (starve_timer != STALL_MAX) starve_timer <= starve_timer + 1'd1;
    if (!stream_seek_wait) seek_timer <= 0;
    else if (seek_timer != STALL_MAX) seek_timer <= seek_timer + 1'd1;
    if (stream_seek_wait && seek_resp_s[2] == seek_req_toggle) begin
      if (seek_timer >= SLOW_30MS) seek_slowest <= 2'd3;
      else if (seek_timer >= SLOW_10MS && seek_slowest < 2'd2) seek_slowest <= 2'd2;
      else if (seek_slowest == 2'd0) seek_slowest <= 2'd1;
    end
  end
  always @(posedge clk_sys) begin
    seek_resp_s <= {seek_resp_s[1:0], seek_resp_toggle};
    pos_req_s <= {pos_req_s[1:0], pos_req_toggle};
    if (pos_req_s[2] != pos_ack_toggle) begin
      // MSU.sv moves rd_addr as soon as the game writes a seek, before msu_apf hears of it,
      // so flag positions taken during a seek
      pos_value <= rd_addr;
      pos_seeking <= rd_seek || seek_pending || seek_active;
      pos_ack_toggle <= pos_req_s[2];
    end
  end

  // Data cache: the word under rd_addr plus a prefetch of the next one
  reg [22:0] cur_word = 0;
  reg [15:0] cur_q = 0;
  reg [15:0] next_q = 0;
  reg next_valid = 0;

  wire [22:0] rd_word = wrap(rd_addr[23:1]);
  wire [15:0] rd_q = (rd_word == cur_word) ? cur_q : next_q;
  assign rd_dout = rd_addr[0] ? rd_q[15:8] : rd_q[7:0];

  localparam ST_IDLE = 0;
  localparam ST_WAIT = 1;
  localparam ST_ACK = 2;

  reg [1:0] st = ST_IDLE;
  reg [1:0] wait_cnt = 0;
  // What the in-flight read fills
  localparam DST_CUR = 0;
  localparam DST_NEXT = 1;
  localparam DST_REPLAY = 2;
  reg [1:0] dst = DST_CUR;

  // Audio replay engine
  reg [2:0] replay_req_s = 0;
  reg replaying = 0;
  reg [8:0] rp_idx = 0;  // 16-bit word within the sector
  reg [9:0] rp_left = 0;  // 16-bit words still to read
  wire [22:0] replay_sni_word = AUD_WORD_BASE | ({replay_slot, rp_idx} & AUD_WORD_MASK);
  reg old_seek = 0;

  // The reader crossed into the prefetched word: shift it in and fetch the one after
  wire prefetch_go = st == ST_IDLE && !msu_data_download && !seek_active && next_valid
      && rd_word == wrap(cur_word + 1'd1) && !starving;
  wire copy_go = st == ST_IDLE && copying && copy_q_ok && copy_word_ready && !prefetch_go;
  // SNI word of the buffered word being copied (copy_cur_base is 4-byte aligned)
  wire [22:0] copy_msu_word = copy_cur_base[23:1] + {copy_idx, 1'b0} + copy_half;
  wire [22:0] copy_sni_word = copy_cur_audio ? AUD_WORD_BASE | (copy_msu_word & AUD_WORD_MASK)
      : wrap_in(copy_cur_region, copy_msu_word);

  always @(posedge clk_sys) begin
    replay_wr <= 0;
    replay_req_s <= {replay_req_s[1:0], replay_req_toggle};
    if (!replaying && replay_req_s[2] != replay_done_toggle) begin
      replaying <= 1;
      rp_idx <= 0;
      rp_left <= 10'((12'(replay_len) + 1'd1) >> 1);
    end else if (replaying && rp_left == 0 && st == ST_IDLE) begin
      replaying <= 0;
      replay_done_toggle <= replay_req_s[2];
    end
    req0_s <= {req0_s[1:0], copy_req_toggle[0]};
    req1_s <= {req1_s[1:0], copy_req_toggle[1]};
    fill0_s <= {fill0_s[1:0], fill_done_toggle[0]};
    fill1_s <= {fill1_s[1:0], fill_done_toggle[1]};
    arrived0_d <= arrived0;
    arrived1_d <= arrived1;
    filled_d <= filled;

    if (load_valid && !load_bank) arrived0 <= arrived0 + 1'd1;
    if (load_valid && load_bank) arrived1 <= arrived1 + 1'd1;
    // msu_apf requests a bank ~30 clk_74a cycles before APF's first word for it
    if (req0_s[2] != req_seen[0]) begin
      req_seen[0] <= req0_s[2];
      base0 <= copy_base[23:0];
      fbase0 <= copy_base[29:0];
      region0 <= copy_region;
      audio0 <= copy_audio;
      len0 <= copy_len;
      arrived0 <= 0;
      filled[0] <= 0;
      pending[0] <= 1;
    end
    if (req1_s[2] != req_seen[1]) begin
      req_seen[1] <= req1_s[2];
      base1 <= copy_base[23:0];
      fbase1 <= copy_base[29:0];
      region1 <= copy_region;
      audio1 <= copy_audio;
      len1 <= copy_len;
      arrived1 <= 0;
      filled[1] <= 0;
      pending[1] <= 1;
    end
    if (fill0_s[2] != fill_seen[0]) begin
      fill_seen[0] <= fill0_s[2];
      filled[0] <= 1;
    end
    if (fill1_s[2] != fill_seen[1]) begin
      fill_seen[1] <= fill1_s[2];
      filled[1] <= 1;
    end
    // A seek can start while a prefetch is in flight; remember it until ST_IDLE
    old_seek <= rd_seek;
    if (rd_seek && !old_seek) seek_pending <= 1;
    if (!rd_seek) seek_active <= 0;

    // cbuf_q follows copy_idx one cycle later
    copy_q_ok <= copying;
    if (!copying && pending[eng_bank]) begin
      copying <= 1;
      copy_idx <= 0;
      copy_half <= 0;
      copy_cur_base <= eng_bank ? base1 : base0;
      copy_cur_fbase <= eng_bank ? fbase1 : fbase0;
      copy_cur_region <= eng_bank ? region1 : region0;
      copy_cur_audio <= eng_bank ? audio1 : audio0;
      copy_left <= ((eng_bank ? len1 : len0) + 2'd3) >> 2;
      copy_q_ok <= 0;
    end else if (copying && copy_left == 0) begin
      copying <= 0;
      if (copy_cur_audio) ;
      else if (copy_cur_region) avail_end1 <= copy_cur_fbase + (eng_bank ? len1 : len0);
      else avail_end0 <= copy_cur_fbase + (eng_bank ? len1 : len0);
      pending[eng_bank] <= 0;
      copy_done_toggle[eng_bank] <= req_seen[eng_bank];
      eng_bank <= ~eng_bank;
    end

    case (st)
      ST_IDLE: begin
        if (prefetch_go) begin
          // First, as the game reads without waiting; the copy has no deadline
          cur_word <= wrap(cur_word + 1'd1);
          cur_q <= next_q;
          next_valid <= 0;
          sni_addr <= {1'b1, wrap(cur_word + 23'd2), 1'b0};
          sni_rd_req <= 1;
          dst <= DST_NEXT;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (copy_go && copy_left != 0) begin
          // Low half first, at the word's address; the high half follows at +2
          sni_addr <= {1'b1, copy_sni_word, 1'b0};
          sni_din <= copy_half ? cbuf_q[31:16] : cbuf_q[15:0];
          copy_half <= ~copy_half;
          if (copy_half) begin
            copy_idx <= copy_idx + 1'd1;
            copy_left <= copy_left - 1'd1;
          end
          sni_wr_req <= 1;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (!msu_data_download && seek_pending && stream_mode && !stream_seek_wait) begin
          // Streaming: have msu_apf buffer from here first (copies keep flowing meanwhile)
          seek_pending <= 0;
          seek_active <= 1;
          rd_seek_done <= 0;
          next_valid <= 0;
          seek_addr <= rd_addr;
          seek_req_toggle <= ~seek_req_toggle;
          stream_seek_wait <= 1;
        end else if (stream_seek_wait && seek_resp_s[2] == seek_req_toggle) begin
          // The reader is now in the region msu_apf answered with
          stream_seek_wait <= 0;
          read_region <= seek_region;
          cur_word <= wrap_in(seek_region, rd_addr[23:1]);
          sni_addr <= {1'b1, wrap_in(seek_region, rd_addr[23:1]), 1'b0};
          sni_rd_req <= 1;
          dst <= DST_CUR;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (!msu_data_download && seek_pending && !stream_mode) begin
          // MSU.sv holds data_seek until rd_seek_done rises
          seek_pending <= 0;
          seek_active <= 1;
          rd_seek_done <= 0;
          next_valid <= 0;
          cur_word <= rd_word;
          sni_addr <= {1'b1, rd_word, 1'b0};
          sni_rd_req <= 1;
          dst <= DST_CUR;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (replaying && rp_left != 0) begin
          // Audio ring to msu_audio: ~0.35ms a sector, well ahead of its FIFO
          sni_addr <= {1'b1, replay_sni_word, 1'b0};
          sni_rd_req <= 1;
          dst <= DST_REPLAY;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end
      end

      ST_WAIT: begin
        // sni_ready drops one clk_mem cycle after the request and an access takes several,
        // so it is low by the next clk_sys edge; skip that one stale cycle
        if (wait_cnt != 2'd1) wait_cnt <= wait_cnt + 1'd1;
        else if (sni_ready) begin
          last_was_read <= sni_rd_req;
          if (sni_rd_req) begin
            if (dst == DST_REPLAY) begin
              replay_wr <= 1;
              replay_data <= sni_dout;
              rp_idx <= rp_idx + 1'd1;
              rp_left <= rp_left - 1'd1;
            end else if (dst == DST_CUR) cur_q <= sni_dout;
            else begin
              next_q <= sni_dout;
              next_valid <= 1;
            end
          end
          sni_wr_req <= 0;
          sni_rd_req <= 0;
          st <= ST_ACK;
        end
      end

      ST_ACK: begin
        st <= ST_IDLE;
        // Only a completed read advances a seek: copy writes also pass through here
        if (last_was_read && seek_active && dst == DST_CUR && !rd_seek_done) begin
          // Seek: fetch the following word before reporting done
          sni_addr <= {1'b1, wrap(cur_word + 23'd1), 1'b0};
          sni_rd_req <= 1;
          dst <= DST_NEXT;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (last_was_read && seek_active && dst == DST_NEXT && !rd_seek_done) begin
          rd_seek_done <= 1;
        end
      end

      default: st <= ST_IDLE;
    endcase
  end
endmodule
