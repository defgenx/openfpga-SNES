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
   copy is capped at 16MB (`DATA_MAX_SIZE`), and the SNES stays in reset until it finishes.

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

Square 2 (x 72-103) is green, or orange once `stream_underrun` is set: the game read past
`win_end`. It stays orange until the next boot.

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

A `.msu` file up to 16MB (`DATA_MAX_SIZE`) is copied whole at boot this way, chunk by chunk,
and the game then reads it from SDRAM. A larger one, e.g. Super Road Blaster's video, is
streamed:

- **Ring:** SDRAM banks 2-3 become a ring, with file byte X at SDRAM address X mod 16MB
  (`RING_BITS`). Offsets are 30 bits, so files up to 1GB, as on MiSTer. `msu_apf` tracks the
  file bytes `[win_start, win_end)` that are in SDRAM, and
  `fetch_end`, up to which bytes are read or being copied.
- **Seek:** `msu_sdram_store` forwards the seek to `msu_apf` (`data_seek_req_toggle`). If the
  offset is outside the window, the window restarts there, once copies in flight are done. The
  seek completes, and MSU-1's data busy bit clears, once `STREAM_LEAD` (4KB) past it is in
  SDRAM, fetched as a single read. Super Road Blaster gives up ("Timeout while seeking address
  in MSU1 data-file") when a seek waited for 64KB behind a 16KB chunk already in flight.
- **Read-ahead:** starts at the game's first seek. Between other work, `msu_apf` polls the reader's position (`pos_req_toggle`)
  and fetches the next `STREAM_CHUNK` (8KB) while `fetch_end` is less than `STREAM_AHEAD`
  (256KB) past it.
- **Priority:** `.pcm` sector requests go before data chunks.
- **Underrun:** sequential reads cannot wait. If the game reads past `win_end`, it gets stale
  data; `stream_underrun` turns the right-hand debug square orange, and the window restarts at
  the reader if it got past `fetch_end`.

`sim/msu` runs a 40,000-byte file through an 8KB ring (`le_stream`, `be_stream`), with a reader
at full DMA speed.

## Memory

The `.msu` file lives in SDRAM banks 2–3 (16MB), which the controller assigns to port 1/SNI. ROM
uses port 0 (banks 0–1). `msu_sdram_store` goes through the controller's SNI port, which only
starts an access in an idle slot, so it never changes ROM timing. It keeps the current 16-bit
word and prefetches the next, so DMA-speed reads from `$2001` do not stall.

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
