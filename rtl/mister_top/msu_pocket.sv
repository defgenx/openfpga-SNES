// clk_sys half of MSU-1 on the Pocket. See docs/MSU-1.md.
//
// msu_host replaces upstream hps_ext.v: same mounting/missing/ack behaviour, but the
// requests go to target/pocket/msu_apf.sv (clk_74a) as toggles instead of to the HPS.
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

    // .pcm words from msu_bridge_rx, split into msu_audio's 16-bit ioctl writes
    input wire rx_valid,
    input wire [31:0] rx_data,
    output reg msu_audio_wr = 0,
    output reg [15:0] msu_audio_data = 0,

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
  reg [15:0] audio_hi = 0;
  reg audio_hi_pending = 0;

  always @(posedge clk_sys) begin
    msu_audio_wr <= 0;
    if (rx_valid) begin
      msu_audio_wr <= 1;
      msu_audio_data <= rx_data[15:0];
      audio_hi <= rx_data[31:16];
      audio_hi_pending <= 1;
    end else if (audio_hi_pending) begin
      msu_audio_wr <= 1;
      msu_audio_data <= audio_hi;
      audio_hi_pending <= 0;
    end

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

// The .msu data file in SDRAM banks 2-3 (16MB), reached through the controller's SNI
// port, which waits for idle slots and so never disturbs ROM timing on port 0.
// Replaces upstream msu_data_store.sv (DDR3) for the MSU.sv data interface. In stream mode
// the banks are a ring that msu_apf fills around the reader, see docs/MSU-1.md "Streaming".
module msu_sdram_store #(
    parameter RING_BITS = 24
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

    // Load: 32-bit words from msu_bridge_rx while msu_data_download, or any time streaming
    input wire msu_data_download,
    input wire load_valid,
    input wire [23:0] load_addr,
    input wire [31:0] load_data,
    output reg load_overflow = 0,

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
  // Bridge words waiting for their two SNI writes. While streaming, the reader's prefetch
  // goes first, so words can queue up behind it; data_loader-style backpressure is impossible.
  // Registered read so it maps to block RAM; the head is usable one cycle after it lands
  reg [53:0] wq[0:7];  // {word address [23:2], data}
  reg [53:0] wq_q = 0;
  reg [2:0] wq_wp = 0;
  reg [2:0] wq_rp = 0;
  reg [3:0] wq_count = 0;
  reg wq_was_nonempty = 0;
  reg wq_half = 0;  // 1 once the low half of the head word is written
  wire [21:0] pend_waddr = wq_q[53:32];
  wire [31:0] pend_data = wq_q[31:0];

  // Word addresses wrap at the ring size
  localparam [22:0] WORD_MASK = (23'd1 << (RING_BITS - 1)) - 1'd1;
  function automatic [22:0] wrap(input [22:0] w);
    wrap = w & WORD_MASK;
  endfunction

  reg [2:0] seek_resp_s = 0;
  reg [2:0] pos_req_s = 0;
  reg stream_seek_wait = 0;
  reg last_was_read = 0;
  always @(posedge clk_sys) begin
    seek_resp_s <= {seek_resp_s[1:0], seek_resp_toggle};
    pos_req_s <= {pos_req_s[1:0], pos_req_toggle};
    if (pos_req_s[2] != pos_ack_toggle) begin
      pos_value <= rd_addr;
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
  reg dst = DST_CUR;
  reg seek_active = 0;
  reg seek_pending = 0;
  reg old_seek = 0;

  // The reader crossed into the prefetched word: shift it in and fetch the one after
  wire prefetch_go = st == ST_IDLE && !msu_data_download && !seek_active && next_valid
      && rd_word == wrap(cur_word + 1'd1);
  wire write_next = st == ST_IDLE && wq_count != 0 && wq_was_nonempty && !prefetch_go;
  wire load_accept = (msu_data_download || stream_mode) && load_valid;

  always @(posedge clk_sys) begin
    if (load_accept && wq_count != 4'd8) wq[wq_wp] <= {load_addr[23:2], load_data};
    wq_q <= wq[wq_rp];
    wq_was_nonempty <= wq_count != 0;
  end

  always @(posedge clk_sys) begin
    if (load_accept) begin
      if (wq_count == 4'd8) load_overflow <= 1;
      else wq_wp <= wq_wp + 1'd1;
    end

    // A seek can start while a prefetch is in flight; remember it until ST_IDLE
    old_seek <= rd_seek;
    if (rd_seek && !old_seek) seek_pending <= 1;
    if (!rd_seek) seek_active <= 0;

    case (st)
      ST_IDLE: begin
        if (prefetch_go) begin
          // Reads crossed into the prefetched word: shift it in and prefetch the next. First, as
          // the game reads without waiting; a pending write has until the next word to land
          cur_word <= wrap(cur_word + 1'd1);
          cur_q <= next_q;
          next_valid <= 0;
          sni_addr <= {1'b1, wrap(cur_word + 23'd2), 1'b0};
          sni_rd_req <= 1;
          dst <= DST_NEXT;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (write_next) begin
          // Low half first, at the word's address; the high half follows at +2
          sni_addr <= {1'b1, wrap({pend_waddr, wq_half}), 1'b0};
          sni_din <= wq_half ? pend_data[31:16] : pend_data[15:0];
          wq_half <= ~wq_half;
          if (wq_half) wq_rp <= wq_rp + 1'd1;
          sni_wr_req <= 1;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (!msu_data_download && seek_pending && stream_mode && !stream_seek_wait) begin
          // Streaming: have msu_apf buffer from here first (data writes keep flowing meanwhile)
          seek_pending <= 0;
          seek_active <= 1;
          rd_seek_done <= 0;
          next_valid <= 0;
          seek_addr <= rd_addr;
          seek_req_toggle <= ~seek_req_toggle;
          stream_seek_wait <= 1;
        end else if (stream_seek_wait && seek_resp_s[2] == seek_req_toggle) begin
          stream_seek_wait <= 0;
          cur_word <= rd_word;
          sni_addr <= {1'b1, rd_word, 1'b0};
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
        end
      end

      ST_WAIT: begin
        // sni_ready drops one clk_mem cycle after the request and an access takes several,
        // so it is low by the next clk_sys edge; skip that one stale cycle
        if (wait_cnt != 2'd1) wait_cnt <= wait_cnt + 1'd1;
        else if (sni_ready) begin
          last_was_read <= sni_rd_req;
          if (sni_rd_req) begin
            if (dst == DST_CUR) cur_q <= sni_dout;
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
        // Only a completed read advances a seek: streamed data writes also pass through here
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

    wq_count <= wq_count + (load_accept && wq_count != 4'd8) - (write_next && wq_half);
  end
endmodule
