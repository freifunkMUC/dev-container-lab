#!/usr/bin/env bash
# Applies the multi-PoP lab patches to the gateway submodules. Safe to run
# again: a patch that is already applied is skipped.
set -eu
cd "$(dirname "$0")/.."

for mod in wgkex ffbs-ansible; do
	patch_file="${PWD}/multipop/patches/${mod}.patch"
	dir="gateway/packer/${mod}"
	if patch -d "${dir}" -p1 -R -s -f --dry-run < "${patch_file}" >/dev/null 2>&1; then
		echo "${mod}: multi-PoP patch already applied"
	else
		patch -d "${dir}" -p1 -s -f < "${patch_file}"
		echo "${mod}: multi-PoP patch applied"
	fi
done
