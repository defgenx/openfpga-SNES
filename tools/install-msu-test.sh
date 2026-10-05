#!/usr/bin/env bash
# Developer shortcut: package the MSU-1 test core, then install it with the packaged install.sh.
# Takes package-msu.sh's options, plus --sd PATH and --dry-run for the installer:
#
#   tools/install-msu-test.sh [--build] [--rbf FILE] ... [--sd PATH] [--dry-run]
#
# For end users, release/defgenx.SNESMSU.zip carries double-click installers instead.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PKG_ARGS=()
INSTALL_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--sd) INSTALL_ARGS+=(--sd "$2"); shift ;;
		--dry-run | -n) INSTALL_ARGS+=(--dry-run) ;;
		--rbf | --rbf-pal | --rbf-spc) PKG_ARGS+=("$1" "$2"); shift ;;
		-h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) PKG_ARGS+=("$1") ;;
	esac
	shift
done

"$REPO/tools/package-msu.sh" ${PKG_ARGS[@]+"${PKG_ARGS[@]}"}
exec "$REPO/build/msu-package/install.sh" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
