#!/usr/bin/env bash
#
# The Windows counterpart of tools/install_flutter.sh.
#
# Same contract, same reasoning: fetch from Google's own bucket, verify the
# SHA-256 the workflow pinned, unpack into the directory the caller named.
# Split into two scripts rather than one because the archive is `.tar.xz` on
# both platforms but the Windows runner has no `sha256sum` and no `mktemp -d`
# with the same shape, and a script that probes for a dozen tools is harder to
# audit than two that each assume what the runner actually provides.
#
# ## Usage
#
#     FLUTTER_VERSION=3.47.0 FLUTTER_CHANNEL=stable \
#     FLUTTER_SHA256=<digest> tools/install_flutter_windows.sh C:\path\to\flutter

set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: $0 <install-directory>" >&2
	exit 2
fi

: "${FLUTTER_VERSION:?FLUTTER_VERSION must be set}"
: "${FLUTTER_CHANNEL:=stable}"
: "${FLUTTER_SHA256:?FLUTTER_SHA256 must be set; an unverified SDK is not installed}"

target="$1"
archive="flutter_windows_${FLUTTER_VERSION}-${FLUTTER_CHANNEL}.zip"
url="https://storage.googleapis.com/flutter_infra_release/releases/${FLUTTER_CHANNEL}/windows/${archive}"
tmp="./.flutter-install-tmp"

echo "Fetching ${url}"
rm -rf "${tmp}"
mkdir -p "${tmp}"
trap 'rm -rf "${tmp}"' EXIT

curl --fail --location --retry 3 --retry-delay 5 --silent --show-error \
	--output "${tmp}/${archive}" "${url}"

# The digest check is the point of this script. It compares against the value
# the workflow pinned, never against a manifest fetched from the same server
# that served the archive.
echo "${FLUTTER_SHA256}  ${tmp}/${archive}" | sha256sum --check --strict

rm -rf "${target}"
mkdir -p "${target}"
# `unzip` ships with Git Bash on the Windows runner. PowerShell's Expand-Archive
# would also work but writes paths in the runner's own separator, which the
# later `flutter` invocations then have to cope with.
unzip -q "${tmp}/${archive}" -d "${tmp}/unpacked"
mv "${tmp}/unpacked/flutter"/* "${target}/"

if [ ! -x "${target}/bin/flutter.bat" ] && [ ! -f "${target}/bin/flutter.bat" ]; then
	echo "error: ${target}/bin/flutter.bat is missing after unpacking" >&2
	exit 1
fi

echo "Flutter ${FLUTTER_VERSION} (${FLUTTER_CHANNEL}) installed to ${target}"
