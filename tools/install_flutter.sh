#!/usr/bin/env bash
#
# Downloads and verifies the Flutter SDK, then puts it where the caller asked.
#
# ## Why this exists instead of a third-party action
#
# The usual way to get Flutter in CI is `subosito/flutter-action` or similar.
# Those actions are third-party, they are trusted with the whole job, and they
# decide which archive to fetch and whether to check it. This project fetches
# from Google's own first-party bucket and checks the digest itself, so a
# compromised mirror or a tampered action cannot supply a modified SDK that
# then compiles the release artifacts.
#
# The version and digest are supplied by the caller. They are not defaulted
# here: a default that is one workflow's version is a silent way for another
# workflow to build with a different toolchain than it thinks it is.
#
# ## Usage
#
#     FLUTTER_VERSION=3.47.0 FLUTTER_CHANNEL=stable \
#     FLUTTER_SHA256=<digest> tools/install_flutter.sh /path/to/flutter
#
# Exits non-zero on any verification failure, and removes the partially
# unpacked tree so a later step cannot pick up a broken SDK.

set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: $0 <install-directory>" >&2
	exit 2
fi

: "${FLUTTER_VERSION:?FLUTTER_VERSION must be set}"
: "${FLUTTER_CHANNEL:=stable}"
: "${FLUTTER_SHA256:?FLUTTER_SHA256 must be set; an unverified SDK is not installed}"

target="$1"
archive="flutter_linux_${FLUTTER_VERSION}-${FLUTTER_CHANNEL}.tar.xz"
url="https://storage.googleapis.com/flutter_infra_release/releases/${FLUTTER_CHANNEL}/linux/${archive}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Fetching ${url}"
if ! curl --fail --location --retry 3 --retry-delay 5 --silent --show-error \
	--output "${tmp}/${archive}" "${url}"; then
	echo "error: could not download ${url}" >&2
	exit 1
fi

# The digest check is the whole point of this script. It compares against the
# value the workflow pinned, not against a manifest fetched from the same
# server that served the archive: a manifest fetched at run time would be
# controlled by whoever controls the bucket.
echo "${FLUTTER_SHA256}  ${tmp}/${archive}" | sha256sum --check --strict

rm -rf "${target}"
mkdir -p "${target}"
tar -xJf "${tmp}/${archive}" -C "${target}" --strip-components=1

if [ ! -x "${target}/bin/flutter" ]; then
	echo "error: ${target}/bin/flutter is missing after unpacking" >&2
	exit 1
fi

echo "Flutter ${FLUTTER_VERSION} (${FLUTTER_CHANNEL}) installed to ${target}"
