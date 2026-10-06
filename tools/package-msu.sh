#!/usr/bin/env bash
# Package the MSU-1 test core as release/defgenx.SNESMSU.zip: Cores/defgenx.SNESMSU, Platforms/,
# and the double-click installers from tools/installer at the zip root.
#
#   tools/package-msu.sh [--build] [--build-pal] [--build-spc] [--rbf F] [--rbf-pal F] [--rbf-spc F]
#
#   --build / --build-pal / --build-spc   compile that bitstream with Quartus 21.1 in Docker (slow)
#   --release                             compile without the MSU-1 debug overlay
#   --fast                                skip timing analysis (the bitstream is the same)
#   --rbf / --rbf-pal / --rbf-spc FILE    use an existing snes_pocket.rbf for that variant
#
# Without either, the last build output in build/msu-test/ is used. Bitstreams left out of
# the zip are filled in by the installers from Cores/agg23.SNES on the card.
set -euo pipefail

AUTHOR=defgenx
SHORTNAME=SNESMSU
CORE_DIR=$AUTHOR.$SHORTNAME
QUARTUS_IMAGE=${QUARTUS_IMAGE:-raetro/quartus:21.1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK="$REPO/build/msu-test"
PKG="$REPO/build/msu-package"
ZIP="$REPO/release/$CORE_DIR.zip"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# Plain variables per variant: macOS ships bash 3.2, without associative arrays
RBF_ntsc=""
RBF_pal=""
RBF_ntsc_spc=""
BUILDS=()
RELEASE_ARG=""
FAST_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--build) BUILDS+=(ntsc) ;;
		--build-pal) BUILDS+=(pal) ;;
		--build-spc) BUILDS+=(ntsc_spc) ;;
		--release) RELEASE_ARG=release ;;
		--fast) FAST_ARG=fast ;;
		--rbf) RBF_ntsc=$2; shift ;;
		--rbf-pal) RBF_pal=$2; shift ;;
		--rbf-spc) RBF_ntsc_spc=$2; shift ;;
		-h | --help) usage ;;
		*) echo "unknown option $1" >&2; usage ;;
	esac
	shift
done

# Quartus in a scratch copy: the qsf's 4 parallel processors hang under amd64 emulation
build() { # <generate.tcl variant>
	local src="$WORK/src"
	mkdir -p "$WORK"
	rsync -a --delete --exclude .git --exclude build --exclude release --exclude 'sim/msu/build' "$REPO/" "$src/"
	sed -i.bak 's/NUM_PARALLEL_PROCESSORS 4/NUM_PARALLEL_PROCESSORS 1/' "$src/projects/snes_pocket.qsf"
	echo "Building $1 (this takes a long time)..."
	docker run --rm --platform linux/amd64 -v "$src":/build -w /build "$QUARTUS_IMAGE" \
		quartus_sh -t generate.tcl "$1" $RELEASE_ARG $FAST_ARG > "$WORK/build_$1.log" 2>&1 \
		|| { tail -30 "$WORK/build_$1.log"; echo "build failed, see $WORK/build_$1.log" >&2; exit 1; }
	grep -m1 "Logic utilization" "$src/projects/output_files/snes_pocket.fit.summary" || true
	cp "$src/projects/output_files/snes_pocket.rbf" "$WORK/$1.rbf"
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

rbf() { eval "printf '%s' \"\${RBF_$1}\""; }
for v in ${BUILDS[@]+"${BUILDS[@]}"}; do build "$v"; eval "RBF_$v=\"\$WORK/$v.rbf\""; done
for v in ntsc pal ntsc_spc; do
	if [ -z "$(rbf $v)" ] && [ -f "$WORK/$v.rbf" ]; then eval "RBF_$v=\"\$WORK/$v.rbf\""; fi
	if [ -n "$(rbf $v)" ] && [ ! -f "$(rbf $v)" ]; then echo "$(rbf $v) not found" >&2; exit 1; fi
done
[ -n "$RBF_ntsc" ] || { echo "No NTSC bitstream: use --build or --rbf FILE" >&2; exit 1; }

rm -rf "$PKG"
STAGE="$PKG/Cores/$CORE_DIR"
mkdir -p "$STAGE" "$PKG/Platforms/_images"
cp "$REPO"/pkg/pocket/Cores/agg23.SNES/* "$STAGE/"
cp "$REPO/pkg/pocket/Platforms/snes.json" "$PKG/Platforms/"
cp "$REPO/pkg/pocket/Platforms/_images/snes.bin" "$PKG/Platforms/_images/"

# The folder name must match author.shortname, or the Pocket ignores the core
python3 - "$STAGE/core.json" "$AUTHOR" "$SHORTNAME" "$(git -C "$REPO" rev-parse --short HEAD)" <<'EOF'
import datetime, json, sys
path, author, shortname, rev = sys.argv[1:]
core = json.load(open(path))
meta = core["core"]["metadata"]
meta["author"] = author
meta["shortname"] = shortname
meta["description"] = "SNES with MSU-1 (test build " + rev + ")"
meta["url"] = "https://github.com/defgenx/openfpga-SNES/tree/feature/msu1"
meta["version"] = meta["version"] + "-msu1"
meta["date_release"] = datetime.date.today().isoformat()
json.dump(core, open(path, "w"), indent=2)
EOF
sed -i.bak 's/^Port by agg23\./MSU-1 test build of the agg23 port./' "$STAGE/info.txt" && rm "$STAGE/info.txt.bak"

for pair in ntsc:snes_main.rev pal:snes_pal.rev ntsc_spc:snes_spc.rev; do
	v=${pair%%:*}
	rev=${pair#*:}
	if [ -n "$(rbf $v)" ]; then
		reverse "$(rbf $v)" "$STAGE/$rev"
		echo "$rev: $(rbf $v)"
	else
		echo "$rev: not packaged, the installer copies it from Cores/agg23.SNES on the card"
	fi
done

cp "$REPO"/tools/installer/install.sh "$REPO"/tools/installer/install.ps1 \
	"$REPO"/tools/installer/install.bat "$REPO"/tools/installer/install-linux.desktop "$PKG/"
cp "$REPO/tools/installer/MSU1-INSTALL.md" "$PKG/"
chmod +x "$PKG/install.sh" "$PKG/install-linux.desktop"
# Windows batch files need CRLF line endings
python3 -c "import sys; p=sys.argv[1]; d=open(p,'rb').read().replace(b'\r\n',b'\n').replace(b'\n',b'\r\n'); open(p,'wb').write(d)" "$PKG/install.bat"

mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
(cd "$PKG" && zip -qrX "$ZIP" .)
echo "Packaged $ZIP"
