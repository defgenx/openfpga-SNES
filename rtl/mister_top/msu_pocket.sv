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

// The .msu data file in SDRAM banks 2-3 (16MB), reached through the controller's SNI
// port, which waits for idle slots and so never disturbs ROM timing on port 0.
// Replaces upstream msu_data_store.sv (DDR3) for the MSU.sv data interface.
module msu_sdram_store (
    input wire clk_sys,

    // Load: 16-bit words from data_loader while msu_data_download
    input wire msu_data_download,
    input wire load_wr,
    input wire [23:0] load_addr,
    input wire [15:0] load_data,
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
  // Loader FIFO: SNI writes can be delayed by refresh, data_loader cannot be stalled
  reg [39:0] fifo[0:3];
  reg [1:0] fifo_wp = 0;
  reg [1:0] fifo_rp = 0;
  reg [2:0] fifo_count = 0;

  // Data cache: the word under rd_addr plus a prefetch of the next one
  reg [22:0] cur_word = 0;
  reg [15:0] cur_q = 0;
  reg [15:0] next_q = 0;
  reg next_valid = 0;

  wire [22:0] rd_word = rd_addr[23:1];
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

  wire fifo_push = msu_data_download && load_wr;
  wire fifo_pop = st == ST_IDLE && fifo_count != 0;

  always @(posedge clk_sys) begin
    if (fifo_push) begin
      if (fifo_count == 4 && !fifo_pop) load_overflow <= 1;
      else begin
        fifo[fifo_wp] <= {load_addr, load_data};
        fifo_wp <= fifo_wp + 1'd1;
      end
    end
    fifo_count <= fifo_count + (fifo_push && !(fifo_count == 4 && !fifo_pop)) - fifo_pop;

    // A seek can start while a prefetch is in flight; remember it until ST_IDLE
    old_seek <= rd_seek;
    if (rd_seek && !old_seek) seek_pending <= 1;
    if (!rd_seek) seek_active <= 0;

    case (st)
      ST_IDLE: begin
        if (fifo_pop) begin
          sni_addr <= {1'b1, fifo[fifo_rp][39:16]};
          sni_din <= fifo[fifo_rp][15:0];
          sni_wr_req <= 1;
          fifo_rp <= fifo_rp + 1'd1;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (!msu_data_download && seek_pending) begin
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
        end else if (!msu_data_download && !seek_active && next_valid && rd_word == cur_word + 1'd1) begin
          // Reads crossed into the prefetched word: shift it in and prefetch the next
          cur_word <= cur_word + 1'd1;
          cur_q <= next_q;
          next_valid <= 0;
          sni_addr <= {1'b1, cur_word + 23'd2, 1'b0};
          sni_rd_req <= 1;
          dst <= DST_NEXT;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end
      end

      ST_WAIT: begin
        // sni_ready drops within one clk_mem cycle of the request; skip the stale level
        if (wait_cnt != 2'd2) wait_cnt <= wait_cnt + 1'd1;
        else if (sni_ready) begin
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
        if (seek_active && dst == DST_CUR && !rd_seek_done) begin
          // Seek: fetch the following word before reporting done
          sni_addr <= {1'b1, cur_word + 23'd1, 1'b0};
          sni_rd_req <= 1;
          dst <= DST_NEXT;
          wait_cnt <= 0;
          st <= ST_WAIT;
        end else if (seek_active && dst == DST_NEXT && !rd_seek_done) begin
          rd_seek_done <= 1;
        end
      end

      default: st <= ST_IDLE;
    endcase
  end
endmodule
