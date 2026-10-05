#!/usr/bin/env bash
#
# install.sh - install the SNES MSU-1 test core (defgenx.SNESMSU) onto an Analogue Pocket
# microSD card, next to agg23.SNES, which is never modified.
#
#   ./install.sh                 find the SD card, then install
#   ./install.sh --sd /media/me/POCKET
#   ./install.sh --dry-run       show what would be copied, change nothing
#
# Double-click: install-linux.desktop opens this in a terminal. On Windows use install.bat.
#
# Files already on the card are never replaced silently: identical ones are skipped, and
# for each one that differs you are asked (default: keep the card's file). Without a
# terminal (or with --dry-run) nothing on the card is ever replaced.
#
set -euo pipefail

REPO="defgenx/openfpga-SNES"
CORE="defgenx.SNESMSU"
UPSTREAM_CORE="agg23.SNES"
HERE="$(cd "$(dirname "$0")" && pwd)"

SD=""
DRY_RUN=0
while [ $# -gt 0 ]; do
	case "$1" in
		--sd) SD="${2:-}"; shift 2 ;;
		--sd=*) SD="${1#--sd=}"; shift ;;
		--dry-run|-n) DRY_RUN=1; shift ;;
		-h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ask PROMPT DEFAULT -> answer on stdout; without a terminal the default is used
INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
ask() {
	local a=""
	if [ $INTERACTIVE -eq 1 ]; then read -r -p "$1 " a || a=""; fi
	printf '%s' "${a:-$2}"
}

# ---------------------------------------------------------------------------
# 1. Files to install: Cores/ next to this script (release zip), else the latest release
# ---------------------------------------------------------------------------

TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

if [ -f "$HERE/Cores/$CORE/snes_main.rev" ]; then
	SRC="$HERE"
	say "Using the core from $SRC"
else
	command -v curl >/dev/null || die "curl is needed to download the release"
	command -v unzip >/dev/null || die "unzip is needed to unpack the release"
	TMP="$(mktemp -d)"
	# newest release that carries the zip, pre-releases included
	url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" \
		| grep -o "https://[^\"]*/releases/download/[^\"]*/$CORE.zip" | head -1)" || true
	[ -n "$url" ] || die "could not find a release of $REPO with $CORE.zip"
	say "Downloading $url"
	curl -fL --progress-bar -o "$TMP/core.zip" "$url" || die "download failed"
	unzip -q "$TMP/core.zip" -d "$TMP/core"
	SRC="$TMP/core"
fi
[ -f "$SRC/Cores/$CORE/snes_main.rev" ] || die "no core bitstream found in $SRC"

# ---------------------------------------------------------------------------
# 2. Find the SD card
# ---------------------------------------------------------------------------

is_pocket_card() {
	# An Analogue Pocket card has at least one of these at its root
	[ -d "$1/Cores" ] || [ -d "$1/Platforms" ] || [ -d "$1/Assets" ] || [ -d "$1/System" ]
}

if [ -z "$SD" ]; then
	candidates=()
	bases=(/media/"${USER:-}" /run/media/"${USER:-}" /media /mnt /Volumes)
	# Git Bash / MSYS / Cygwin on Windows: drive letters are /d, /e ... (skip the system drive)
	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*)
			bases=()
			for d in /[d-z] /cygdrive/[d-z]; do [ -d "$d" ] && candidates+=("$d"); done ;;
	esac
	for base in ${bases[@]+"${bases[@]}"}; do
		[ -d "$base" ] || continue
		for v in "$base"/*; do
			[ -d "$v" ] && [ -w "$v" ] || continue
			case "$v" in "/Volumes/Macintosh HD"*|/Volumes/Recovery|/Volumes/Preboot) continue ;; esac
			candidates+=("$v")
		done
	done

	pocket=()
	for v in ${candidates[@]+"${candidates[@]}"}; do is_pocket_card "$v" && pocket+=("$v"); done

	if [ ${#pocket[@]} -eq 1 ]; then
		SD="${pocket[0]}"
		say "Found Pocket SD card: $SD"
		case "$(ask "Install there? [Y/n]" y)" in [nN]*) die "aborted" ;; esac
	else
		list=("${pocket[@]+"${pocket[@]}"}")
		[ ${#list[@]} -eq 0 ] && list=("${candidates[@]+"${candidates[@]}"}")
		[ ${#list[@]} -eq 0 ] && die "no writable volume found - insert the SD card, or pass --sd PATH"
		[ ${#pocket[@]} -eq 0 ] && say "No card with Pocket folders found; mounted volumes:"
		[ ${#pocket[@]} -gt 1 ] && say "Several Pocket cards found:"
		i=1
		for v in "${list[@]}"; do say "  $i) $v"; i=$((i + 1)); done
		[ $INTERACTIVE -eq 1 ] || die "several volumes found - pass --sd PATH"
		n="$(ask "Number of the SD card to install to:" "")"
		[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#list[@]} ] || die "invalid choice"
		SD="${list[$((n - 1))]}"
	fi
fi

SD="${SD%/}"
[ -d "$SD" ] || die "$SD is not a directory"
[ -w "$SD" ] || die "$SD is not writable"
is_pocket_card "$SD" || say "Note: $SD has no Cores/Platforms/Assets folders yet; they will be created."

# ---------------------------------------------------------------------------
# 3. Copy, never replacing anything silently. Only Cores/$CORE and Platforms/ are written.
# ---------------------------------------------------------------------------

CP=(cp)
[ "$(uname)" = "Darwin" ] && CP=(cp -X)  # no ._ AppleDouble files on the FAT card

copied=0
replaced=0
same=0
kept=()
policy=""   # "all" = replace every differing file, "none" = keep every one

# install_file SRC REL: copy SRC to $SD/REL, asking before replacing a different file
install_file() {
	local src="$1" rel="$2" dst="$SD/$2" verb="copied  " a
	case "$rel" in "Cores/$UPSTREAM_CORE"/*) die "refusing to write $rel" ;; esac
	if [ -e "$dst" ]; then
		if cmp -s "$src" "$dst"; then same=$((same + 1)); return; fi
		if [ $DRY_RUN -eq 1 ] || [ $INTERACTIVE -eq 0 ] || [ "$policy" = "none" ]; then kept+=("$rel"); return; fi
		if [ "$policy" != "all" ]; then
			a="$(ask "$rel already exists and differs. Replace it? [y]es/[N]o/[a]ll/[s]kip all" n)"
			case "$a" in
				[aA]*) policy="all" ;;
				[sS]*) policy="none"; kept+=("$rel"); return ;;
				[yY]*) ;;
				*) kept+=("$rel"); return ;;
			esac
		fi
		verb="replaced"
	fi
	if [ $DRY_RUN -eq 1 ]; then
		say "would copy  $rel"
	else
		mkdir -p "$(dirname "$dst")"
		"${CP[@]}" "$src" "$dst"
		say "$verb    $rel"
	fi
	if [ "$verb" = "replaced" ]; then replaced=$((replaced + 1)); else copied=$((copied + 1)); fi
}

cd "$SRC"
# file list on fd 3 so the questions can read the terminal on stdin
while IFS= read -r -d '' f <&3; do
	rel="${f#./}"
	case "$(basename "$rel")" in .DS_Store|._*|.keep) continue ;; esac
	install_file "$f" "$rel"
done 3< <(find ./Cores ./Platforms -type f -print0 | sort -z)

# Bitstreams the zip does not carry (PAL, SPC7110/S-DD1/BSX) come from agg23.SNES on the card
for rev in snes_pal.rev snes_spc.rev; do
	if [ ! -f "$SRC/Cores/$CORE/$rev" ]; then
		if [ -f "$SD/Cores/$UPSTREAM_CORE/$rev" ]; then
			install_file "$SD/Cores/$UPSTREAM_CORE/$rev" "Cores/$CORE/$rev"
		else
			say "warning: no $rev in this package or in Cores/$UPSTREAM_CORE; those games will not boot in $CORE"
		fi
	fi
done

[ -f "$SRC/MSU1-INSTALL.md" ] && install_file "$SRC/MSU1-INSTALL.md" "MSU1-INSTALL.md"
# ROMs and MSU-1 packs go here, shared with agg23.SNES
[ $DRY_RUN -eq 1 ] || mkdir -p "$SD/Assets/snes/common"

say ""
if [ $DRY_RUN -eq 1 ]; then say "Dry run: $copied file(s) would be copied to $SD"
else say "Copied $copied new file(s), replaced $replaced, $same already up to date on $SD"; fi
if [ ${#kept[@]} -gt 0 ]; then
	say "Kept the card's version (differs from this package): ${#kept[@]}"
	for s in "${kept[@]}"; do say "  - $s"; done
	[ $INTERACTIVE -eq 0 ] && [ $DRY_RUN -eq 0 ] && say "Run the script in a terminal to be asked about replacing them."
fi
[ $DRY_RUN -eq 1 ] && exit 0

# ---------------------------------------------------------------------------
# 4. Eject
# ---------------------------------------------------------------------------

sync
done_msg="Put the card in the Pocket: Cores > SNES > pick the 'defgenx' core."
case "$(ask "Eject the SD card now? [Y/n]" "$([ $INTERACTIVE -eq 1 ] && echo y || echo n)")" in
	[nN]*) say "Remember to eject the card before removing it. $done_msg" ;;
	*)
		cd /
		if [ "$(uname)" = "Darwin" ]; then
			diskutil eject "$SD" && say "Ejected. $done_msg"
		elif command -v udisksctl >/dev/null; then
			dev="$(df --output=source "$SD" | tail -1)"
			udisksctl unmount -b "$dev" && udisksctl power-off -b "$dev" && say "Ejected. $done_msg"
		else
			umount "$SD" && say "Unmounted. $done_msg"
		fi ;;
esac
