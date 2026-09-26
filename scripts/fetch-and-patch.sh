#!/usr/bin/env bash
#
# Fetch aria2 at the pinned version and apply the Turbo patches.
#
# Shared by every platform build. Keeping the fetch and the patch application
# in one place is the point: the patches are the only reason this fork exists,
# so a platform script that forgets one would produce a binary that looks right
# and behaves differently.
#
# Usage:  scripts/fetch-and-patch.sh <version> <destination> [platform-patch-dir]
#   version            e.g. 1.37.0
#   destination        directory to unpack into (created; must be empty or absent)
#   platform-patch-dir optional; every *.patch in it is applied after the
#                      Turbo set. Used for changes that belong to one target
#                      rather than to this fork as a whole.
#
# Licence: the resulting binary is GPLv3. See LICENSE.

set -euo pipefail

ARIA2_VERSION="${1:?usage: fetch-and-patch.sh <version> <destination>}"
DEST="${2:?usage: fetch-and-patch.sh <version> <destination>}"
PLATFORM_PATCH_DIR="${3:-}"

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
# Apply one patch, or report why it could not be.
#
# The check used to be `patch --dry-run --reverse --silent`, on the reasoning
# that a reverse dry run succeeds exactly when the patch is already in place.
# On the macOS runner it succeeded for all five patches against a tree that had
# just been unpacked, so every one was reported as already applied, none were
# applied, and the consequence appeared much later as a link against a library
# that only exists on Linux. The same check answers correctly under GNU patch
# on this machine, so the difference is in the patch implementation rather than
# in the patch files.
#
# Requiring both answers fixes it without depending on which implementation is
# running: forward succeeds when the patch is still needed, reverse succeeds
# when it is already in place, and neither means the tree is in a state this
# script does not recognise -- worth stopping for rather than guessing at.
apply_patch() {
    local patch_file="$1"
    local name
    name="$(basename "$patch_file")"

    if patch -p1 -s --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "    [apply] $name"
        patch -p1 -s < "$patch_file"
        return 0
    fi

    if patch -p1 -s -R --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "    [skip] $name (already applied)"
        return 0
    fi

    echo "    [fail] $name -- it applies neither forwards nor in reverse"
    echo "           the source tree is in a state this script does not know"
    return 1
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

# Platform patches come last, and are applied in filename order.
#
# These are not part of the fork's identity the way the Turbo set is -- they
# fix something that is only wrong on one target. Keeping them separate is what
# lets the Windows and Linux binaries stay byte-comparable with the reference
# build while iOS gets the corrections it needs.
if [ -n "$PLATFORM_PATCH_DIR" ] && [ -d "$PLATFORM_PATCH_DIR" ]; then
    for patch_file in "$PLATFORM_PATCH_DIR"/*.patch; do
        [ -e "$patch_file" ] || continue
        apply_patch "$patch_file"
    done
fi

# Patched configure.ac makes every generated autotools file look stale.
#
# The release tarball ships aclocal.m4, configure, config.h.in and the
# Makefile.in files already generated, and each of them lists configure.ac among
# its prerequisites. Patching configure.ac gives it a newer timestamp than all
# of them, so make decides they need rebuilding and shells out to automake,
# which the runner does not have in a matching version:
#
#     missing: line 81: aclocal-1.16: command not found
#     make: *** [aclocal.m4] Error 127
#
# Touching them restores what is actually true -- the generated files match the
# patched source, because the patches change behaviour and not the build
# description. The order is the dependency order, oldest first, so that every
# file ends up newer than the ones it is generated from:
#
#     aclocal.m4  <- configure.ac
#     config.h.in <- aclocal.m4
#     Makefile.in <- aclocal.m4
#     configure   <- aclocal.m4
refresh_generated() {
    [ -e aclocal.m4 ] && touch aclocal.m4
    [ -e config.h.in ] && touch config.h.in
    find . -name 'Makefile.in' -exec touch {} +
    [ -e configure ] && touch configure
}

refresh_generated

echo "==> patched"
