# MSU-1

MSU-1 support reuses the upstream MiSTer chip logic unchanged (`rtl/upstream/chip/MSU1/`:
`MSU.sv` registers, `msu_audio.v` player). On MiSTer, the rest happens on the ARM side
(`Main_MiSTer/support/snes/snes.cpp`) plus `hps_ext.v`, and the data file sits in DDR3.
The Pocket has neither, so two Pocket modules replace them:

| File | Clock | Replaces |
|---|---|---|
| `target/pocket/msu_apf.sv` | `clk_74a` | The HPS file handling: finds and opens files via APF target commands |
| `rtl/mister_top/msu_pocket.sv` → `msu_host` | `clk_sys` | `hps_ext.v`: track mounting/missing and sector ack handshakes |
| `rtl/mister_top/msu_pocket.sv` → `msu_sdram_store` | `clk_sys` | `msu_data_store.sv` + DDR3: the `.msu` file in SDRAM |

MSU is built into all three bitstreams (`USE_MSU` in `generate.tcl`): `main`, `PAL` and
`SPCSDD1`. The chip32 loader picks one from the ROM header, so a pack must work whichever it
picks.

## File lookup

Files follow the MiSTer convention: `<base>.msu` and `<base>-<n>.pcm` next to the ROM, where
`<base>` is the ROM path without its extension and `<n>` is the track number in decimal with
no leading zeros.

At every ROM load, `msu_apf` holds the SNES in reset (`msu_busy`) and runs this sequence once the
chip32 loader has been quiet for ~14ms and the core is running:

1. `0x0190` Get Filename on slot 0 (the cartridge). The path lands in the scratch struct.
2. The FSM finds the last `.` after the last `/`, and writes `.msu` there.
3. `0x0192` Open File into slot 20. If it succeeds, MSU-1 is enabled. As on MiSTer, an empty
   `.msu` still enables MSU-1.
4. The opened size is read from the data slot table (`0x2000`), which APF updates on open.
5. If the size is non-zero, `0x0180` Data Slot Read copies the file to bridge region `0x4`. The
   copy is capped at 8MB (`DATA_MAX_SIZE`), and the SNES stays in reset until it finishes.

If any command goes unanswered for ~0.9s during this probe, MSU-1 stays off and the game boots
normally.

The filename struct's byte order is taken from where the path's leading `/` lands in word 0,
falling back to `bridge_endian_little`.

### Probe diagnostic

APF samples bridge read data long after `bridge_rd`, by when `bridge_addr` may have moved on,
so the scratch RAM latches the read address at the strobe (as `data_unloader.sv` does). Before
that, APF read a garbage path for Open File; test build 3 reported it in yellow.

With the **MSU-1 Debug Squares** setting on (`interact.json` id 50, bridge `0x300`, off by
default), two 32x32 squares are drawn near the top-left corner (`target/pocket/msu_overlay.sv`). Square 1 (x 32-63) shows the boot probe result:

| Colour | Result |
|---|---|
| Dark grey | No probe has run yet |
| Light grey | Probe in progress (copying a large `.msu` file takes several seconds) |
| Green | MSU-1 enabled (`<rom>.msu` opened). If the game still plays its original music, the ROM is not the MSU-1 patched one, or the `.pcm` names do not match |
| Red | `<rom>.msu` not found: check that its name matches the ROM's |
| Yellow | Open File: malformed path |
| Orange | Open File: slot undefined |
| Cyan | Open File: general error |
| Pink | Open File: another result code |
| Blue | Get Filename on the cartridge slot failed |
| White | The ROM path has no terminator or is too long to extend |
| Magenta | APF did not answer a command in time |

Square 2 (x 72-103) is orange once `stream_underrun` is set (the game read past `win_end`; it
stays orange until the next boot). Otherwise it shows `seek_slowest`, the longest streaming seek
since boot including any freeze: gray none yet, green under 10ms, yellow under 30ms, red 30ms or
more.

While streaming, a bar (y 72-79, x 32-95) shows `stream_fill`: the bytes between the reader and
`win_end`, in 1/64ths of `STREAM_AHEAD`, sampled at each fetch decision.

The overlay is compiled in when `core_top`'s `MSU_DEBUG` parameter is 1. That is the default;
`generate.tcl <variant> release` sets it to 0, and the unused diagnostic logic is then pruned.

`sim/overlay/tb_overlay.sv` checks the squares' placement and the bar behind `scanline_filler`.

## CPU turbo

CPU turbo is forced off while MSU-1 is enabled, the way upstream forces it off for SA-1
(`TURBO_ALLOW`). On hardware, an MSU-1 game with turbo on booted to a black screen, and another
reported the MSU-1 chip missing.

## Streaming

Every `.msu` read goes through a **bounce buffer**: two 8KB banks of block RAM in
`msu_sdram_store`. Before each read, `msu_apf` claims a bank (`copy_req_toggle[bank]`, with
`copy_base`/`copy_len`). The store copies each word to SDRAM as soon as it lands, between the
game's reads, which go first. After the read, `fill_done_toggle[bank]` marks the chunk
complete, and `copy_done_toggle[bank]` returns once all of it is in SDRAM; only then is the bank
reused. Chunks alternate banks and complete in order.

Nothing can be dropped this way. On hardware, a write queue fed straight from the bridge
overflowed while the game read, and Super Road Blaster then executed garbage ("BRK encountered
... Hdma::init()"). Copying as words arrive, rather than after a whole chunk, keeps a seek's
latency to APF's read time: copying after the fact brought back "Timeout while seeking address
in MSU1 data-file".

A `.msu` file up to 8MB (`DATA_MAX_SIZE`) is copied whole at boot this way, chunk by chunk,
and the game then reads it from SDRAM. A larger one, e.g. Super Road Blaster's video, is
streamed:

- **Ring and windows:** SDRAM banks 2-3 become a ring, split into two 4MB regions, one per
  window. Offsets are 30 bits, so files up to 1GB, as on MiSTer. Windows are tracked in 1KB
  pages, which keeps `msu_apf`'s comparators narrow (it is near the FPGA's size limit); a new
  window starts on the seek's page, and only the file's last read is shorter than a page
  multiple. The *active* window holds file
  bytes `[win_start, win_end)` in SDRAM, with `[win_end, fetch_end)` being read and copied, and
  is read ahead. The *parked* window keeps `[park_start, park_end)` from the window the game
  left. Super Road Blaster seeks every frame between a chapter's frame table and the frame
  data; with one window, every such jump restarted it cold on the SD card.
- **Seek:** `msu_sdram_store` forwards the seek to `msu_apf` (`data_seek_req_toggle`).
  - Inside the active window: kept.
  - Inside the parked window: the two swap, with no SD access.
  - Elsewhere: the active window is parked and a new one starts at the seek, in the other
    region.

  Switching windows waits for chunks being copied. The seek completes, and MSU-1's data busy
  bit clears, once at least `STREAM_LEAD` (4KB) past it is in SDRAM (the first read is 5KB from
  the seek's page); `seek_region` tells the store which
  region the reader is now in. The game allows about 30ms per seek: it polls MSU_STATUS `$2000`
  times (`MSU1_SEEK_TIMEOUT` in its source).
- **Freeze on a slow seek:** APF keeps its file fragment cache for the last-accessed slot only,
  so a data read after a `.pcm` read walks the `.msu` cluster chain again; an open plus a read
  takes ~30ms on hardware (measured by the openFPGA Mega CD core), and firmware events such as
  plugging in USB power stop bridge service for hundreds of ms. Once a streaming seek has waited
  `STALL_AFTER`, `msu_sdram_store` raises `stall`, which drives the SNES `enable` in
  `main.v` low: CPU, PPU, SMP and DSP freeze together (the CPU keeps its own H/V counters, so it
  cannot freeze alone), video output pauses, and MSU-1 audio and the fetch path keep running.
  The freeze starts after `STALL_AFTER` (20ms; the game allows ~30ms), so seeks that complete
  sooner never freeze. `STALL_MAX` (1.5s) releases a seek that never completes.
- **Freeze on underrun:** after the first streaming seek, the store also freezes the console
  when sequential reads reach `avail_end`, the end of the data copied into the reader's region
  (from each chunk's `copy_base` + `copy_len`), and holds the prefetch meanwhile, so the game
  never reads data that has not arrived.
- **Audio ring:** `.pcm` sectors are played from a 1MB ring in SDRAM (1024 sectors, ~6s of
  audio, SNI word `0x400000` up), never read from APF on request. `msu_apf` keeps the current
  track's sectors `[aud_start, aud_end)` there, with `[aud_end, aud_fetch)` being read, and
  answers each `msu_audio` sector request with a replay (`replay_req_toggle`): the store reads
  the sector from the ring into `msu_audio` in ~0.35ms. Replays have their own small FSM
  (`rp_state`) beside the main one, so they are served while an APF read is in flight: an 8KB
  read takes a few ms and one after a slot change tens of ms, longer than the ~23ms FIFO. A request outside the ring (track
  start, a loop point or resume already evicted) restarts it there. The track is read ahead
  in bursts of 8KB reads, from under `AUD_LOW` (176 sectors, ~1s) ahead of the last request up
  to `AUD_HIGH` (352, ~2s); during a burst `.msu` read-ahead waits unless a seek needs data. So
  the slot changes about twice a second instead of around every sector, and the 256KB `.msu`
  read-ahead covers each burst. `msu_audio` is upstream's, with its 4KB (~23ms) FIFO: a
  restart outside the ring (a loop point of a track over ~6s, once evicted) waits for an APF
  read, which can leave a short gap if the slot has to change. Sector numbers are 18 bits:
  tracks up to 256MB.
- **Reader position:** `msu_apf` polls it (`pos_req_toggle`) to decide on read-ahead. `MSU.sv`
  moves the address as soon as the game writes a seek, so the store flags positions taken
  during a seek (`pos_seeking`), and they are ignored.
- **Read-ahead:** starts at the game's first seek. Between other work, `msu_apf` polls the reader's position (`pos_req_toggle`)
  and fetches the next `STREAM_CHUNK` (8KB) while `fetch_end` is less than `STREAM_AHEAD`
  (256KB) past it.
- **Priority:** a waiting `msu_audio` request (replay, or the read it waits for), then seek
  bookkeeping, then a seek's data, then an audio burst, then `.msu` read-ahead.
- **Underrun:** the store freezes the reader at `avail_end` (above); `stream_underrun` still
  turns the right-hand debug square orange when `msu_apf` sees the reader past `win_end`, and
  the window restarts at the reader if it got past `fetch_end`.

`sim/msu` runs a 40,000-byte file through an 8KB ring (`le_stream`, `be_stream`), with a reader
at full DMA speed. The `srb` case replays Super Road Blaster's pattern with the hardware's lead
and chunk sizes and music playing at its real rate. The mock APF there charges 300µs per read
and 3ms whenever the slot changes (`CMD_US`, `SWITCH_US`). It fails any seek over 30ms: the
longest is 16.6ms, and 22.8ms with a 10ms switch penalty.

Game scenarios in `sim/msu` (run them all with `make -C sim/msu`):

| Case | Modeled on | Checks |
|---|---|---|
| `srb` | Super Road Blaster (FMV) | 92 seeks: frame table / frame data / palette every frame, with music; every seek under 30ms |
| `z3r` | ALttP randomizer (`z3randomizer` `msu.asm`), the usual audio-pack code | Empty `.msu`, ident, pack detection (tracks 1, 101), a 64-track fallback scan with missing tracks, fades, stop with resume and continuing from the saved sector |
| `video` | MSU-1 video players | One seek, then 6KB per vblank at 60Hz (360KB/s, about what a SNES can move to VRAM) with music, no underrun |
| `video_fast` | Same, as a stress test | 12KB per vblank (720KB/s) |

The z3r track files are realistic lengths: a track under 2KB hits the upstream `msu_audio`
quirk below.

**APF's file cache:** the [openFPGA 2.1 changelog](https://www.analogue.co/developer/docs/openfpga/changelog/2-1)
says a target read walks the file's cluster chain and caches up to 16 fragments, so later reads
of the same slot seek instantly, but the cache is lost whenever another data slot is accessed.
Music (slot 21) and data (slot 20) both need reading while a video plays; the audio ring keeps
the slot changes to about two a second, each paying that walk once.

## Memory

The `.msu` file lives in SDRAM banks 2–3 (an 8MB ring, `RING_BITS` 23, then the 1MB audio
ring), which the controller assigns to port 1/SNI. ROM
uses port 0 (banks 0–1). `msu_sdram_store` goes through the controller's SNI port, which only
starts an access in an idle slot, so it never changes ROM timing. It keeps the current 16-bit
word and prefetches the next, so DMA-speed reads from `$2001` do not stall.

`psram.sv` (WRAM and ARAM) samples write data one `clk_mem` cycle after it sees `write_en`, with
a matching multicycle path in `core_constraints.sdc`: sampling on the first cycle left up to
~5ns of negative slack from the CPU and DMA data paths, so a write could store the previous
value.

`rfs1` is wired as upstream does it (`RFSH` in reset, the SNES `REFRESH` otherwise). It is the
controller's only auto-refresh trigger. Without it, banks 2–3 are never refreshed, because
nothing activates their rows between MSU reads.

## Behaviour inherited from upstream

- `msu_audio` raises stop once the last sector is *fetched*. It drops what is still queued in its
  FIFO (up to 767 samples, ~17ms) at the end of a non-repeating track.
- A track whose only partial sector directly follows sector 0 (a file under 2KB) loses that
  partial sector.

## Fit and timing

With MSU-1, the NTSC bitstream uses 17,604 of 18,480 ALMs (95%). Two changes make that fit:

- `bram.patch` turns off upstream's In-System Memory Content Editor hint (~460 ALMs).
- `snes_pocket.qsf` optimizes for area (`AGGRESSIVE AREA`, no register duplication).

Setup timing still fails on the 21.48MHz and 85.9MHz clocks, as it does without MSU-1. The
failing paths run between the SNES CPU and the memories; none of them is in MSU logic.
`core_constraints.sdc` named the SDRAM `ic|nes|sdram` instead of `ic|snes|sdram`, which
silently dropped its multicycle constraints.

## Testing

`make -C sim/msu` (Verilator 5) runs the real `core_bridge_cmd`, `data_loader`, `msu_apf`,
`msu_host`, `msu_sdram_store`, `MSU.sv` and `msu_audio.v` against a mock APF and an SNI model. It
covers both bridge endiannesses and a ROM without MSU files. It checks the `.msu` preload, seeks
and reads on the data port, a missing track, a full track and a looping track sample by sample.
The vendor and VHDL primitives (`dcfifo`, `CEGen`, `mf_datatable`) are behavioural stubs in
`sim/msu/stubs.v`.

The mock answers immediately, so the sim proves the protocol, not real-hardware latency. On the
Pocket, sector reads must still keep ahead of 44.1kHz playback: about 172 sectors/s, with a
4-sector FIFO.
