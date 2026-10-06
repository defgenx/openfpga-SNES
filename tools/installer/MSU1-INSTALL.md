# SNES MSU-1 test core for the Analogue Pocket

Installs `defgenx.SNESMSU` next to the regular `agg23.SNES` core, which is left untouched.

1. Unzip this archive and insert the Pocket's SD card.
2. Run `install.bat` on Windows, `install-linux.desktop` or `./install.sh` on Linux, `./install.sh` on macOS.

The installer finds the card and asks before replacing any file that differs.

Put the MSU-1 pack next to the ROM, with the same base name (`game.sfc`, `game.msu`, `game-1.pcm`, ...).

To remove it, delete `Cores/defgenx.SNESMSU` from the card.
