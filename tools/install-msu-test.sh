#!/usr/bin/env bash
# Install this branch as a separate Pocket core, "defgenx.SNESMSU", next to agg23.SNES.
# Cores/agg23.SNES on the card is never touched. Both cores share ROMs (/Assets/snes/common)
# and saves (/Saves/snes/common), since the save format is the same.
#
#   tools/install-msu-test.sh <sd-root> [--build] [--build-pal] [--rbf FILE] [--rbf-pal FILE]
#
#   --build        compile the NTSC (main) bitstream with Quartus 21.1 in Docker (slow)
#   --build-pal    also compile the PAL bitstream
#   --rbf FILE     use an existing NTSC snes_pocket.rbf instead of building
#   --rbf-pal FILE use an existing PAL snes_pocket.rbf
#
# A bitstream that is neither built nor given is copied from Cores/agg23.SNES on the card,
# so PAL games boot without MSU-1 unless a PAL bitstream is provided. SPCSDD1 never has MSU-1.
set -euo pipefail

CORE_DIR=defgenx.SNESMSU
QUARTUS_IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK="$REPO/build/msu-test"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ $# -ge 1 ] || usage
SD=${1%/}
shift
BUILD_NTSC=0
BUILD_PAL=0
RBF_NTSC=""
RBF_PAL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--build) BUILD_NTSC=1 ;;
		--build-pal) BUILD_PAL=1 ;;
		--rbf) RBF_NTSC=$2; shift ;;
		--rbf-pal) RBF_PAL=$2; shift ;;
		*) usage ;;
	esac
	shift
done

[ -d "$SD" ] || { echo "SD card root '$SD' not found" >&2; exit 1; }
[ -d "$SD/Cores" ] || { echo "'$SD' has no Cores/ folder: is this the Pocket SD card?" >&2; exit 1; }
AGG="$SD/Cores/agg23.SNES"

# Quartus in a scratch copy: the qsf's 4 parallel processors hang under amd64 emulation
build() { # <generate.tcl variant> <output rbf>
	local src="$WORK/src"
	mkdir -p "$WORK"
	rsync -a --delete --exclude .git --exclude build --exclude 'sim/msu/build' "$REPO/" "$src/"
	sed -i.bak 's/NUM_PARALLEL_PROCESSORS 4/NUM_PARALLEL_PROCESSORS 1/' "$src/projects/snes_pocket.qsf"
	echo "Building $1 (this takes a long time)..."
	docker run --rm --platform linux/amd64 -v "$src":/build -w /build "$QUARTUS_IMAGE" \
		quartus_sh -t generate.tcl "$1" > "$WORK/build_$1.log" 2>&1 \
		|| { tail -30 "$WORK/build_$1.log"; echo "build failed, see $WORK/build_$1.log" >&2; exit 1; }
	cp "$src/projects/output_files/snes_pocket.rbf" "$2"
	grep -m1 "Logic utilization" "$src/projects/output_files/snes_pocket.fit.summary" || true
}

# APF wants the rbf with the bit order of every byte reversed
reverse() { # <rbf> <rev>
	python3 - "$1" "$2" <<'EOF'
import sys
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data.translate(table))
EOF
}

mkdir -p "$WORK"
if [ $BUILD_NTSC = 1 ]; then build ntsc "$WORK/ntsc.rbf"; RBF_NTSC="$WORK/ntsc.rbf"; fi
if [ $BUILD_PAL = 1 ]; then build pal "$WORK/pal.rbf"; RBF_PAL="$WORK/pal.rbf"; fi
[ -n "$RBF_NTSC" ] || { echo "Need --build or --rbf FILE for the NTSC (MSU-1) bitstream" >&2; exit 1; }

STAGE="$WORK/stage/$CORE_DIR"
rm -rf "$WORK/stage"
mkdir -p "$STAGE"
cp "$REPO"/pkg/pocket/Cores/agg23.SNES/* "$STAGE/"

python3 - "$STAGE/core.json" "$(git -C "$REPO" rev-parse --short HEAD)" <<'EOF'
import json, sys
path, rev = sys.argv[1], sys.argv[2]
core = json.load(open(path))
meta = core["core"]["metadata"]
meta["author"] = "defgenx"
meta["shortname"] = "SNESMSU"
meta["description"] = "SNES with MSU-1 (test build " + rev + ")"
meta["url"] = "https://github.com/defgenx/openfpga-SNES/tree/feature/msu1"
meta["version"] = meta["version"] + "-msu1"
json.dump(core, open(path, "w"), indent=2)
EOF
sed -i.bak 's/^Port by agg23\./MSU-1 test build of the agg23 port./' "$STAGE/info.txt" && rm "$STAGE/info.txt.bak"

reverse "$RBF_NTSC" "$STAGE/snes_main.rev"
if [ -n "$RBF_PAL" ]; then
	reverse "$RBF_PAL" "$STAGE/snes_pal.rev"
elif [ -f "$AGG/snes_pal.rev" ]; then
	echo "PAL: using agg23's bitstream (no MSU-1)"
	cp "$AGG/snes_pal.rev" "$STAGE/"
else
	echo "warning: no PAL bitstream; PAL games will not boot in $CORE_DIR" >&2
fi
if [ -f "$AGG/snes_spc.rev" ]; then
	cp "$AGG/snes_spc.rev" "$STAGE/"
else
	echo "warning: no SPCSDD1 bitstream; SPC7110/S-DD1/BSX games will not boot in $CORE_DIR" >&2
fi

rm -rf "${SD:?}/Cores/$CORE_DIR"
cp -R "$STAGE" "$SD/Cores/"
# The platform is shared with agg23.SNES; only add it if the card lacks it
if [ ! -f "$SD/Platforms/snes.json" ]; then
	mkdir -p "$SD/Platforms/_images"
	cp "$REPO/pkg/pocket/Platforms/snes.json" "$SD/Platforms/"
	cp "$REPO/pkg/pocket/Platforms/_images/snes.bin" "$SD/Platforms/_images/"
fi
mkdir -p "$SD/Assets/snes/common"
command -v dot_clean >/dev/null && dot_clean -m "$SD/Cores/$CORE_DIR" 2>/dev/null || true

echo "Installed $SD/Cores/$CORE_DIR. On the Pocket: Cores > SNES > pick the 'defgenx' core."
echo "MSU-1 packs go next to the ROM: game.sfc, game.msu, game-1.pcm, ... (see docs/MSU-1.md)"
