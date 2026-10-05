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

MSU is built into the `main` (NTSC) and `PAL` bitstreams (`USE_MSU` in `generate.tcl`), but
not into `SPCSDD1`.

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

Track requests (`$2004/$2005`) rewrite the suffix as `-<n>.pcm` and Open File it into slot 21. A
size of 0 reports the track as missing. Each audio sector request is a Data Slot Read of 1024 bytes
at `sector * 1024`, clamped to the end of the file, delivered to bridge region `0x5`. Only slot 21
is read while a game plays, so APF's per-slot cluster cache stays warm.

Slots 20 and 21 are declared in `data.json` as `deferload`, read-only and not user-selectable;
APF requires every slot the core opens to be declared.

## Bridge map

| Region | Use |
|---|---|
| `0x3000_0000` | Filename struct for Get/Open File (path at `0x0`, flags at `0x100`, size at `0x104`) — `msu_apf` scratch RAM |
| `0x4xxx_xxxx` | `.msu` contents → `data_loader` → `msu_sdram_store` → SDRAM |
| `0x5xxx_xxxx` | `.pcm` sector → `data_loader` → `msu_audio` (the `ioctl` stream on MiSTer) |

`core_top.sv` gives the data slot table's port A to `msu_apf` while `dt_active` is set; the rest
of the time, that port reports the save size.

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
