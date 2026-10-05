# SNES MSU-1 test core for the Analogue Pocket

This installs a second SNES core, `defgenx.SNESMSU`, next to the regular `agg23.SNES` core.
The regular core is not modified: pick either one from the SNES entry in Cores on the Pocket.

> **Experimental**: MSU-1 on the Pocket has not been tested on hardware yet.

## Install

1. Unzip this archive anywhere on your computer and insert the Pocket's SD card.
2. Run the installer:
   - **Windows**: double-click `install.bat`.
   - **Linux**: double-click `install-linux.desktop` (on GNOME, right-click it and choose
     *Allow Launching* the first time), or run `./install.sh` in a terminal.
   - **macOS**: run `./install.sh` in a terminal.
3. The installer finds the card, asks before installing, copies the core, and offers to eject.

Files that already exist on the card and differ are never replaced without asking.

## MSU-1 packs

Put the pack next to the ROM, with the same base name:

```
/Assets/snes/common/Zelda MSU/zelda.sfc
/Assets/snes/common/Zelda MSU/zelda.msu      (required, may be empty)
/Assets/snes/common/Zelda MSU/zelda-1.pcm
/Assets/snes/common/Zelda MSU/zelda-2.pcm
...
```

The `.msu` data file is copied to memory at boot (a short black screen for large packs).
Only its first 16MB are available. Both cores share ROMs and saves.

## Troubleshooting

This test build draws two small squares near the top-left corner of the picture. The left one
shows MSU-1 detection: green = found, red = `<rom>.msu` not found (check the names), light gray
= still loading. The README's "Troubleshooting MSU-1" section lists every colour:
https://github.com/defgenx/openfpga-SNES/tree/feature/msu1#troubleshooting-msu-1

## Remove

Delete the `Cores/defgenx.SNESMSU` folder from the SD card.
