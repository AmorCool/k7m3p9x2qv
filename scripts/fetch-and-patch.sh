#!/usr/bin/env bash
#
# Fetch aria2 at the pinned version and apply the Turbo patches.
#
# Shared by every platform build. Keeping the fetch and the patch application
# in one place is the point: the patches are the only reason this fork exists,
# so a platform script that forgets one would produce a binary that looks right
# and behaves differently.
#
# Usage:  scripts/fetch-and-patch.sh <version> <destination>
#   version      e.g. 1.37.0
#   destination  directory to unpack into (created; must be empty or absent)
#
# Licence: the resulting binary is GPLv3. See LICENSE.

set -euo pipefail

ARIA2_VERSION="${1:?usage: fetch-and-patch.sh <version> <destination>}"
DEST="${2:?usage: fetch-and-patch.sh <version> <destination>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PATCH_DIR="$ROOT_DIR/patch"

# Same ordering as upstream aria2. The release tarball is preferred over a git
# clone because it ships a working configure and does not need autoreconf,
# which keeps the Windows and iOS cross-builds free of a full autotools
# bootstrap.
TARBALL_URL="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VERSION}/aria2-${ARIA2_VERSION}.tar.xz"

echo "==> aria2 ${ARIA2_VERSION}"
echo "    destination: $DEST"

if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    echo "    already populated, skipping fetch"
else
    mkdir -p "$DEST"
    echo "    fetching $TARBALL_URL"
    # Downloaded to a file first, then unpacked. A pipe straight into tar
    # reports a network failure as a corrupt archive, and a failed attempt has
    # already consumed part of the stream.
    ARCHIVE="$DEST/.aria2.tar.xz"
    curl -fsSL -o "$ARCHIVE" "$TARBALL_URL"
    tar -xJ -C "$DEST" --strip-components=1 -f "$ARCHIVE"
    rm -f "$ARCHIVE"
fi

cd "$DEST"

# `git apply` needs a repository. The tarball has none, and running
# `git init` inside the build tree writes a .git directory into what we are
# about to compile, so patch(1) is used instead -- it is what git apply shells
# out to for this kind of input anyway.
apply_patch() {
    local patch_file="$1"
    local name
    name="$(basename "$patch_file")"

    # Already applied? Several of these touch the same file, and a rerun after
    # a failed build must not double-apply. `patch --dry-run -R` succeeds
    # exactly when the patch is already in place.
    if patch -p1 --dry-run --reverse --silent < "$patch_file" >/dev/null 2>&1; then
        echo "    [skip] $name (already applied)"
        return 0
    fi

    echo "    [apply] $name"
    patch -p1 --forward --silent < "$patch_file"
}

# Order matters only in that all of them must land. Independent hunks, but
# 0001 and 0004 both edit OptionHandlerFactory.cc, so line offsets shift.
#
# These four are the set the reference Turbo build applies, and they are applied
# unconditionally so that a binary from here behaves like one from there.
apply_patch "$PATCH_DIR/0001-options-unlock-connection-per-server-limit.patch"
apply_patch "$PATCH_DIR/0002-download-retry-on-slow-speed-and-reset.patch"
apply_patch "$PATCH_DIR/0003-option-add-option-to-retry-on-http-4xx.patch"
apply_patch "$PATCH_DIR/0004-option-set-no-want-digest-header-default-to-true.patch"

# 0005 is not part of that set. It raises the stock defaults (split 5 -> 32 and
# min-split-size 20M -> 1M) so that the unlocked ceilings are used without the
# user configuring anything first, which is a behaviour change rather than a
# bug fix and is therefore opt-in:
#
#     TURBO_DEFAULTS=1 scripts/fetch-and-patch.sh 1.37.0 /tmp/aria2
#
# Left off, the defaults are upstream's and only the ceilings differ -- the
# same thing the reference build ships.
if [ "${TURBO_DEFAULTS:-0}" = "1" ]; then
    apply_patch "$PATCH_DIR/0005-options-raise-the-split-default.patch"
fi

echo "==> patched"
