# SNES for Analogue Pocket

Ported from the original core developed by [srg320](https://github.com/srg320) ([Patreon](https://www.patreon.com/srg320)). Latest upstream available at https://github.com/MiSTer-devel/SNES_MiSTer.

Please report any issues encountered to this repo. Most likely any problems are a result of my port, not the original core. Issues will be upstreamed as necessary.

> [!WARNING]
> 
> Savestates/Memories/Sleep not supported
>
> Savestates/Memories/Sleep are not supported by any FPGA SNES core. Not this one, not the MiSTer core it's ported from, not the Analogue Super NT one.
> 
> **Support for savestates will _not_ be coming** to any of these cores. Do not ask. If you would like to learn more, see [issue #59](https://github.com/agg23/openfpga-SNES/issues/59) and [this discussion on the MiSTer forums](https://misterfpga.org/viewtopic.php?t=4944).

## Installation

### Easy mode

I highly recommend the updater tools by [@mattpannella](https://github.com/mattpannella) and [@RetroDriven](https://github.com/RetroDriven). If you're running Windows, use [the RetroDriven GUI](https://github.com/RetroDriven/Pocket_Updater), or if you prefer the CLI, use [the mattpannella tool](https://github.com/mattpannella/pocket_core_autoupdate_net). Either of these will allow you to automatically download and install openFPGA cores onto your Analogue Pocket. Go donate to them if you can

### Manual mode
To install the core, copy the `Assets`, `Cores`, and `Platform` folders over to the root of your SD card. Please note that Finder on macOS automatically _replaces_ folders, rather than merging them like Windows does, so you have to manually merge the folders.

## Usage

ROMs should be placed in `/Assets/snes/common`. Both headered and unheadered ROMs are now supported.

## Features

### Dock Support

Core supports four players/controllers via the Analogue Dock. To enable four player mode, turn on `Use Multitap` setting.

### Expansion Chips

All original expansion chips supported by MiSTer are also supported on the Pocket. The full list is:

* SA-1 (Super Mario RPG)
* Super FX/GSU-1/2 (Star Fox)
* DSP (Super Mario Kart)
* CX4 (Mega Man X 2)
* S-DD1 (Star Ocean)
* SPC7110 (Far East of Eden)
* ST1010 (F1 Roc 2)
* BSX (Satellaview)

The Super Game Boy, ST011 (Hayazashi Nidan Morita Shougi), and ST018 (Hayazashi Nidan Morita Shougi 2) are not supported in the MiSTer core, and therefore are not supported here.

#### MSU-1

> **Warning**: Experimental, being tested on hardware

The homebrew MSU-1 chip (CD-quality audio tracks and a streamed data file) is supported in all bitstreams, using the MiSTer naming scheme. Put the pack next to the ROM, with the same base name:

```
/Assets/snes/common/Zelda MSU/zelda.sfc
/Assets/snes/common/Zelda MSU/zelda.msu      (required, may be empty)
/Assets/snes/common/Zelda MSU/zelda-1.pcm
/Assets/snes/common/Zelda MSU/zelda-2.pcm
...
```

To try it without touching the regular core, install the test build as a separate core, `defgenx.SNESMSU`. Unzip `defgenx.SNESMSU.zip` from the [releases](https://github.com/defgenx/openfpga-SNES/releases), then run `install.bat` on Windows, `install-linux.desktop` on Linux, or `./install.sh` in a terminal. To package one from a bitstream, use `tools/package-msu.sh`.

MSU-1 is enabled when `<rom>.msu` exists. A data file up to 16MB is copied to memory at boot (expect a short black screen for large ones). A larger one, such as an FMV game's video, is streamed from the SD card while the game plays. See [docs/MSU-1.md](docs/MSU-1.md) for how it works.

##### Region

The **Region** setting (Auto, NTSC or PAL) overrides the 50/60Hz mode the ROM header asks for. The loader still picks the NTSC or PAL bitstream from the header before the core starts, so a forced region runs on the other region's clock, about 0.9% fast or slow.

##### Troubleshooting MSU-1

Turn on **MSU-1 Debug Squares** in the core's settings menu to draw two small squares near the top-left corner of the picture. They are off by default, and stay on while the setting is on.

**Left square: MSU-1 detection at boot**

| Color | What happened | What to do |
|---|---|---|
| Dark gray | Detection has not run yet | Wait; if it stays, report it |
| Light gray | Detection in progress; a large `.msu` file is being copied (a few seconds) | Wait |
| Green | MSU-1 found and enabled | If the game still plays its original music, the ROM is not the MSU-1 patched one, or the `.pcm` names do not match the ROM's |
| Red | `<rom>.msu` not found | Put `game.msu` next to `game.sfc`, with exactly the same base name. ROMs without a pack always show red |
| Yellow | The Pocket rejected the path as malformed | Report it, with the ROM's full path |
| Orange | The Pocket says the MSU-1 data slot is undefined | Reinstall the core (`data.json` is out of date) |
| Cyan | The Pocket hit a general error opening the `.msu` | Check the SD card; report it |
| Pink | The Pocket returned another error code | Report it |
| Blue | The Pocket did not return the ROM's path | Report it |
| White | The ROM path is unreadable or too long | Shorten the folder or file name |
| Magenta | The Pocket did not answer within ~7s | Report it |

**Right square: the core's requests to the Pocket**

| Color | What happened |
|---|---|
| Green | The last request was answered (normal) |
| Blue | No request answered yet (normal before detection) |
| Yellow | The Pocket accepted a request but has not finished it (a large `.msu` copy, for a few seconds) |
| Red | A request is waiting and the Pocket has not picked it up |
| Magenta | The Pocket never acknowledged the core at startup |
| White | Streamed `.msu` data was lost (stays white until the next boot) |

CPU turbo is switched off automatically while MSU-1 is enabled, because MSU-1 games do not run reliably with it.

FMV games such as Super Road Blaster stream their video from the `.msu` file. If the game reports bad video frames (e.g. `video-frame FE01 of chapter B479 is bad`), the stream did not keep up with it. With the debug squares on, a white right-hand square means streamed data was lost; please report it.

##### Building the MSU-1 core on Windows

Install [Quartus Prime Lite 21.1](https://www.intel.com/content/www/us/en/software-kit/684215/intel-quartus-prime-lite-edition-design-software-version-21-1-for-windows.html) with Cyclone V support, clone this branch, then double-click `tools\build-windows.bat`. It compiles the NTSC, PAL and SPC7110/S-DD1/BSX bitstreams, writes `release\defgenx.SNESMSU.zip`, and runs the installer. From PowerShell, `tools\build-windows.ps1 -Variants ntsc` builds one bitstream only, and `-PackageOnly` repackages the last build.

#### BSX

BSX ROMs must be patched to run without BIOS. The BSX BIOS is not currently supported

### Savestates/Memories/Sleep

> **Warning**: Not supported

Savestates/Memories/Sleep are not supported by any FPGA SNES core. Not this one, not the MiSTer core it's ported from, not the Analogue Super NT one.

**Support for savestates will _not_ be coming** to any of these cores. Do not ask. If you would like to learn more, see [issue #59](https://github.com/agg23/openfpga-SNES/issues/59) and [this discussion on the MiSTer forums](https://misterfpga.org/viewtopic.php?t=4944).

### Video

* `Square Pixels` - The internal resolution of the SNES is a 8:7 pixel aspect ratio (wide pixels), which roughly corresponds to what users would see on 4:3 display aspect ratio CRTs. Some games are designed to be displayed at 8:7 PAR (the core's default), and others at 1:1 PAR (square pixels). The `Square Pixels` option is provided to switch to a 1:1 pixel aspect ratio
* `Pseudo Transparency` - Enable blending of adjacent pixels, used in some games to simulate transparency

### Turbo

* `CPU Turbo` - Applies a speed increase to the main SNES CPU. **NOTE:** This has different compatibility with different games. See the [MiSTer list of games](https://github.com/MiSTer-devel/SNES_MiSTer/blob/master/SNES_Turbo.md) that this feature works with
* `SuperFX Turbo` - Applies a speed increase to the GSU (SuperFX) chip. Can be used in addition to the `CPU Turbo` option in games like Star Fox to maintain a higher frame rate.

### Controller Options

There are several options provided for selecting which type of controller the core will emulate.

* `Gamepad` - The standard SNES controller used with most games.
* `Super Scope` - The Super Scope lightgun that's used with most lightgun games. See Lightguns for more details.
* `Justifier` - The Justifier lightgun that's used with Lethal Enforcers. See Lightguns for more details.
* `Mouse` - The SNES mouse that's used with Mario Paint and several other games. See SNES Mouse for more details.

### Lightguns

Core supports virtual lightguns by selecting the `Super Scope` or `Justifier` options under `Controller Options`. Most lightgun games user the Super Scope but Lethal Enforcers uses the Justifier. The crosshair can be controlled with the D-Pad or left joystick, using the A button to fire and the B button to reload. D-Pad aim sensitivity can be adjusted with the `D-Pad Aim Speed` setting.

**NOTE:** Joystick support for aiming only appears to work when a controller is paired over Bluetooth and not connected to the Analogue Dock directly by USB.

### SNES Mouse

Core supports a virtual SNES mouse by selecting `Mouse` under `Controller Options`. The mouse can be moved with the D-Pad or left joystick and left and right clicks can be performed by pressing the A and B buttons respectively. Mouse D-Pad movement sensitivity can be adjusted with the `D-Pad Aim Speed` setting.

**NOTE:** The dock firmware doesn't currently support a USB mouse.