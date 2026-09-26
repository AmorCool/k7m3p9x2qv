#!/usr/bin/env bash
#
# aria2 for iOS, built with the Xcode command-line toolchain.
#
# Must run on macOS. `xcrun` is the whole toolchain story here: clang, the
# linker, libtool and the SDK paths all come from it, so there are no extra
# cross-toolchain downloads and nothing to keep in sync with Xcode.
#
# What gets produced, and why two things:
#
#   build/ios/<sdk>/libaria2.a   static library, for linking into an app
#   build/ios/<sdk>/aria2c       Mach-O executable, for running as a child
#
# The app that consumes this needs the executable form: it spawns a helper
# process rather than linking aria2 into its own address space, which keeps
# the GPL boundary at the process edge and lets the downloader crash without
# taking the UI with it. The static library is produced too because it is
# nearly free once the objects exist and it keeps the door open for the
# other integration style.
#
# Deployment target: 18.0, matching the consuming project. Overridable.
#
# Licence: GPLv3. See LICENSE. Shipping the binary means shipping the source
# of this fork, including the patches, which is why they live in this repo.

set -euo pipefail

SDK="${1:-iphoneos}"                   # iphoneos | iphonesimulator
ARIA2_VERSION="${ARIA2_VERSION:-1.37.0}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"
ARCH="${ARCH:-arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/ios/$SDK}"
ARIA2_SRC="$BUILD_ROOT/aria2"
PREFIX="$BUILD_ROOT/deps"
OUT_DIR="$BUILD_ROOT"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SDK_PATH="$(xcrun -sdk "$SDK" -show-sdk-path)"
CC_BIN="$(xcrun -sdk "$SDK" -f clang)"
CXX_BIN="$(xcrun -sdk "$SDK" -f clang++)"

export CC="$CC_BIN"
export CXX="$CXX_BIN"
export AR="$(xcrun -f ar)"
export RANLIB="$(xcrun -f ranlib)"
export STRIP="$(xcrun -f strip)"
export LIBTOOL="$(xcrun -f libtool)"

# -arch and the sysroot have to go through CFLAGS/CXXFLAGS rather than --host,
# because Apple's clang is not a target-triple compiler: `--host=arm-apple-darwin`
# produces a triple that autoconf accepts but clang does not act on. Passing the
# flags explicitly is the supported way to cross-compile to iOS.
TRIPLE_CFLAGS="-arch $ARCH -isysroot $SDK_PATH"
case "$SDK" in
    iphoneos)        PLATFORM_FLAGS="-miphoneos-version-min=$DEPLOYMENT_TARGET" ;;
    iphonesimulator) PLATFORM_FLAGS="-mios-simulator-version-min=$DEPLOYMENT_TARGET" ;;
    *) echo "unknown sdk: $SDK" >&2; exit 1 ;;
esac

export CFLAGS="$TRIPLE_CFLAGS $PLATFORM_FLAGS -O2 -fembed-bitcode-marker"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$TRIPLE_CFLAGS $PLATFORM_FLAGS"

# autoconf's link tests need the same treatment or every configure check fails
# with "cannot run C compiled programs" -- the binary is a Mach-O for a
# different platform and the build host refuses to execute it.
export ac_cv_exeext=""
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

echo "==> aria2 $ARIA2_VERSION for $SDK ($ARCH)"
echo "    sdk:        $SDK_PATH"
echo "    deploy:     $DEPLOYMENT_TARGET"

source "$ROOT_DIR/dependences"

# ---------------------------------------------------------------------------
# Dependencies
#
# Same versions as the Linux builds. jemalloc is included here (unlike
# Windows): iOS has the POSIX VM layer it needs, and the allocator matters
# more on a phone than on a desktop.
# ---------------------------------------------------------------------------

# Download and unpack a dependency.
#
# The decompressor is chosen from the URL rather than tried in sequence. Trying
# each one in turn looks harmless and is not: a failed `tar -J` has already
# consumed part of the stream, so the following attempt sees a truncated
# archive and the one after that has nothing left. The visible symptom is
# `curl: (23) Failure writing output to destination` followed by a build that
# runs in an empty directory.
fetch() {
    local dir="$1" url="$2"
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        return 0
    fi

    local flag
    case "$url" in
        *.tar.xz|*.txz)   flag="-J" ;;
        *.tar.bz2|*.tbz2) flag="-j" ;;
        *.tar.gz|*.tgz)   flag="-z" ;;
        *) echo "unsupported archive type: $url" >&2; return 1 ;;
    esac

    mkdir -p "$dir"
    echo "==> fetch $(basename "$url")"
    # A temporary file rather than a pipe into tar, so a network failure is
    # reported as a network failure instead of as a corrupt archive.
    local archive="$dir/.download"
    # A half-unpacked tree looks populated and would be skipped on a retry, so
    # a failure removes it. The guard is what makes a rerun after a network
    # blip actually redo the work.
    if ! curl -fsSL -o "$archive" "$url"; then
        rm -rf "$dir"
        return 1
    fi
    if ! tar -x "$flag" -C "$dir" --strip-components=1 -f "$archive"; then
        rm -rf "$dir"
        return 1
    fi
    rm -f "$archive"
}

do_build() {
    local name="$1"
    echo "==> build $name"
    make -j"$JOBS" >/dev/null
    make install >/dev/null
}

mkdir -p "$BUILD_ROOT/zlib" && cd "$BUILD_ROOT/zlib"
fetch "$BUILD_ROOT/zlib" "$ZLIB"
if [ ! -f .configured ]; then
    ./configure --prefix="$PREFIX" --static
    touch .configured
fi
do_build zlib

mkdir -p "$BUILD_ROOT/expat" && cd "$BUILD_ROOT/expat"
fetch "$BUILD_ROOT/expat" "$EXPAT"
if [ ! -f .configured ]; then
    ./configure --host="$ARCH-apple-darwin" --prefix="$PREFIX" \
        --enable-static --disable-shared --without-examples --without-tests \
        --without-docbook
    touch .configured
fi
do_build expat

mkdir -p "$BUILD_ROOT/c-ares" && cd "$BUILD_ROOT/c-ares"
fetch "$BUILD_ROOT/c-ares" "$C_ARES"
if [ ! -f .configured ]; then
    ./configure --host="$ARCH-apple-darwin" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-tests
    touch .configured
fi
do_build c-ares

# OpenSSL has its own configure. The one thing that must not be guessed is the
# target name: `iphoneos-cross` is the preset that knows about the iOS SDK
# layout, and `no-asm` is required because the perlasm output is not
# compatible with the arm64 Darwin ABI. `no-shared` keeps it a .a.
mkdir -p "$BUILD_ROOT/openssl" && cd "$BUILD_ROOT/openssl"
fetch "$BUILD_ROOT/openssl" "$OPENSSL"
if [ ! -f .configured ]; then
    CROSS_TOP="$(dirname "$(dirname "$SDK_PATH")")"
    CROSS_SDK="$(basename "$SDK_PATH")"
    export CROSS_TOP CROSS_SDK
    export CROSS_COMPILE=""
    if [ "$SDK" = "iphoneos" ]; then
        ./Configure iphoneos-cross no-asm no-shared no-tests no-docs -DL_ENDIAN \
            --prefix="$PREFIX"
    else
        ./Configure iossimulator-xcrun no-asm no-shared no-tests no-docs -DL_ENDIAN \
            --prefix="$PREFIX"
    fi
    touch .configured
fi
echo "==> build openssl"
# build_libs skips the apps, which cannot be built for iOS anyway.
make -j"$JOBS" build_libs >/dev/null
make install_sw >/dev/null

mkdir -p "$BUILD_ROOT/sqlite3" && cd "$BUILD_ROOT/sqlite3"
fetch "$BUILD_ROOT/sqlite3" "$SQLITE3"
if [ ! -f .configured ]; then
    ./configure --host="$ARCH-apple-darwin" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-dynamic-extensions
    touch .configured
fi
do_build sqlite3

mkdir -p "$BUILD_ROOT/libssh2" && cd "$BUILD_ROOT/libssh2"
fetch "$BUILD_ROOT/libssh2" "$LIBSSH2"
if [ ! -f .configured ]; then
    ./configure --host="$ARCH-apple-darwin" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-examples-build
    touch .configured
fi
do_build libssh2

mkdir -p "$BUILD_ROOT/jemalloc" && cd "$BUILD_ROOT/jemalloc"
fetch "$BUILD_ROOT/jemalloc" "$JEMALLOC"
if [ ! -f .configured ]; then
    # jemalloc's configure probes for a working `je_` prefix and for the page
    # size; on iOS both are answered rather than detected.
    ./configure --host="$ARCH-apple-darwin" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-stats \
        je_cv_force_defined_je_prefix=no
    touch .configured
fi
echo "==> build jemalloc"
make -j"$JOBS" >/dev/null
make install >/dev/null

# ---------------------------------------------------------------------------
# aria2
# ---------------------------------------------------------------------------

"$ROOT_DIR/scripts/fetch-and-patch.sh" "$ARIA2_VERSION" "$ARIA2_SRC"
cd "$ARIA2_SRC"

# The ca-bundle path is baked in at configure time on iOS as elsewhere. There
# is no system store to point at, so it names the copy the app ships.
CA_BUNDLE="/usr/share/aria2/ca-bundle.crt"

if [ ! -f .configured ]; then
    ./configure \
        --host="$ARCH-apple-darwin" \
        --prefix="$PREFIX" \
        --with-libz \
        --with-libcares \
        --with-libexpat \
        --without-libxml2 \
        --without-libgcrypt \
        --with-openssl \
        --without-libnettle \
        --without-gnutls \
        --without-libgmp \
        --with-libssh2 \
        --with-sqlite3 \
        --with-jemalloc \
        --with-ca-bundle="$CA_BUNDLE" \
        ARIA2_STATIC=yes \
        --disable-shared \
        --enable-static
    touch .configured
fi

echo "==> build aria2c"
make -j"$JOBS" >/dev/null

mkdir -p "$OUT_DIR"

# Static library: every object except the one holding main().
echo "==> archive libaria2.a"
OBJS="$(find src -name '*.o' ! -name 'aria2c-main.o' ! -name 'main.o' | sort)"
if [ -n "$OBJS" ]; then
    # shellcheck disable=SC2086
    "$LIBTOOL" -static -o "$OUT_DIR/libaria2.a" $OBJS
fi

# Executable. Kept out of the app bundle's Frameworks and shipped as a
# separate helper so the licence boundary is the process boundary.
cp src/aria2c "$OUT_DIR/aria2c"
"$STRIP" "$OUT_DIR/aria2c" || true

echo "==> output"
ls -la "$OUT_DIR/libaria2.a" "$OUT_DIR/aria2c" 2>/dev/null || true
file "$OUT_DIR/aria2c" 2>/dev/null || true
