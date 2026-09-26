#!/usr/bin/env bash
#
# aria2 for Windows, cross-compiled with mingw-w64.
#
# Run from an ordinary Linux shell (or MSYS2) with the mingw-w64 toolchain on
# PATH. `HOST` selects the target, exactly as upstream's Dockerfile.mingw does:
#
#   HOST=x86_64-w64-mingw32 ./platform/windows/build.sh   # 64-bit
#   HOST=i686-w64-mingw32   ./platform/windows/build.sh   # 32-bit
#
# The dependency recipe is taken from the source tree's own `mingw-build-memo`
# rather than invented here. Three of its details are load bearing and are easy
# to get wrong:
#
#   * OpenSSL needs `--cross-compile-prefix`. Passing only a target name
#     produces a library that configures cleanly and then fails to link,
#     because the compiler prefix is what makes its Configure use the mingw
#     toolchain at all.
#   * c-ares and libssh2 both need `LIBS="-lws2_32"`; without Winsock they fail
#     at the link step.
#   * libssh2 uses `--with-crypto=wincng` upstream, which routes its crypto
#     through the Windows API. That is kept, so libssh2 does not drag a second
#     OpenSSL into the binary.
#
# Upstream's mingw-config builds with `--without-openssl`, which would leave
# the binary unable to fetch HTTPS. This fork requires HTTPS, so OpenSSL is
# built and enabled -- that is the one deliberate departure from their recipe.
#
# Output: build/windows/<arch>/aria2c.exe
#
# Licence: GPLv3. See LICENSE.

set -euo pipefail

HOST_TRIPLE="${HOST:-x86_64-w64-mingw32}"
ARIA2_VERSION="${ARIA2_VERSION:-1.37.0}"

case "$HOST_TRIPLE" in
    x86_64-w64-mingw32) ARCH="x64"; OPENSSL_TARGET="mingw64" ;;
    i686-w64-mingw32)   ARCH="x86"; OPENSSL_TARGET="mingw" ;;
    *) echo "unsupported HOST: $HOST_TRIPLE" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/windows/$ARCH}"
ARIA2_SRC="$BUILD_ROOT/aria2"
PREFIX="$BUILD_ROOT/deps"
OUT_DIR="$BUILD_ROOT"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

export CC="${HOST_TRIPLE}-gcc"
export CXX="${HOST_TRIPLE}-g++"
export AR="${HOST_TRIPLE}-ar"
export RANLIB="${HOST_TRIPLE}-ranlib"
export STRIP="${HOST_TRIPLE}-strip"
export LD="${HOST_TRIPLE}-ld"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# dpkg-architecture is not present on every host; fall back to the toolchain's
# own idea of the build machine.
BUILD_TRIPLE="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE 2>/dev/null || echo "$(uname -m)-pc-linux-gnu")"

CA_BUNDLE="C:/ProgramData/aria2/ca-bundle.crt"

echo "==> aria2 $ARIA2_VERSION for Windows ($ARCH, $HOST_TRIPLE)"

source "$ROOT_DIR/dependences"

fetch() {
    local dir="$1" url="$2"
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        return 0
    fi
    mkdir -p "$dir"
    echo "==> fetch $(basename "$url")"
    curl -fsSL "$url" | tar -x --strip-components=1 -C "$dir" -J 2>/dev/null ||
        curl -fsSL "$url" | tar -x --strip-components=1 -C "$dir" -z 2>/dev/null ||
        curl -fsSL "$url" | tar -x --strip-components=1 -C "$dir" -j
}

do_build() {
    echo "==> build $1"
    make -j"$JOBS" >/dev/null
    make install >/dev/null
}

# zlib has no --host support; it reads the toolchain from these variables.
mkdir -p "$BUILD_ROOT/zlib" && cd "$BUILD_ROOT/zlib"
fetch "$BUILD_ROOT/zlib" "$ZLIB"
if [ ! -f Makefile ]; then
    ./configure \
        --prefix="$PREFIX" \
        --libdir="$PREFIX/lib" \
        --includedir="$PREFIX/include" \
        --static
fi
do_build zlib

mkdir -p "$BUILD_ROOT/expat" && cd "$BUILD_ROOT/expat"
fetch "$BUILD_ROOT/expat" "$EXPAT"
if [ ! -f Makefile ]; then
    ./configure --host="$HOST_TRIPLE" --build="$BUILD_TRIPLE" \
        --prefix="$PREFIX" --disable-shared --enable-static \
        --without-examples --without-tests --without-docbook
fi
do_build expat

# Winsock has to be named explicitly; the configure link test does not find it.
mkdir -p "$BUILD_ROOT/c-ares" && cd "$BUILD_ROOT/c-ares"
fetch "$BUILD_ROOT/c-ares" "$C_ARES"
if [ ! -f Makefile ]; then
    ./configure --host="$HOST_TRIPLE" --build="$BUILD_TRIPLE" \
        --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-tests --without-random \
        LIBS="-lws2_32"
fi
do_build c-ares

# OpenSSL: --cross-compile-prefix is the part that matters.
mkdir -p "$BUILD_ROOT/openssl" && cd "$BUILD_ROOT/openssl"
fetch "$BUILD_ROOT/openssl" "$OPENSSL"
if [ ! -f Makefile ]; then
    ./Configure \
        --cross-compile-prefix="${HOST_TRIPLE}-" \
        --prefix="$PREFIX" \
        no-shared no-tests \
        "$OPENSSL_TARGET"
fi
echo "==> build openssl"
make -j"$JOBS" >/dev/null
make install_sw >/dev/null

mkdir -p "$BUILD_ROOT/sqlite3" && cd "$BUILD_ROOT/sqlite3"
fetch "$BUILD_ROOT/sqlite3" "$SQLITE3"
if [ ! -f Makefile ]; then
    ./configure --host="$HOST_TRIPLE" --build="$BUILD_TRIPLE" \
        --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-dynamic-extensions
fi
do_build sqlite3

# --with-crypto=wincng keeps libssh2 on the Windows crypto API.
mkdir -p "$BUILD_ROOT/libssh2" && cd "$BUILD_ROOT/libssh2"
fetch "$BUILD_ROOT/libssh2" "$LIBSSH2"
if [ ! -f Makefile ]; then
    ./configure --host="$HOST_TRIPLE" --build="$BUILD_TRIPLE" \
        --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-examples-build --with-crypto=wincng \
        LIBS="-lws2_32"
fi
do_build libssh2

# jemalloc has no Windows port: it needs mmap and a POSIX VM layer. aria2
# builds without it; the allocator is a performance choice, not a requirement.
echo "==> skipping jemalloc on Windows (unsupported)"

# ---------------------------------------------------------------------------
# aria2
# ---------------------------------------------------------------------------

"$ROOT_DIR/scripts/fetch-and-patch.sh" "$ARIA2_VERSION" "$ARIA2_SRC"
cd "$ARIA2_SRC"

if [ ! -f Makefile ]; then
    ./configure \
        --host="$HOST_TRIPLE" \
        --build="$BUILD_TRIPLE" \
        --prefix="$PREFIX" \
        --without-included-gettext \
        --disable-nls \
        --with-libz \
        --with-libcares \
        --with-libexpat \
        --without-libxml2 \
        --with-openssl \
        --without-libgcrypt \
        --without-libnettle \
        --without-gnutls \
        --without-libgmp \
        --with-libssh2 \
        --with-sqlite3 \
        --without-jemalloc \
        --with-ca-bundle="$CA_BUNDLE" \
        ARIA2_STATIC=yes \
        --disable-shared \
        --enable-static \
        CPPFLAGS="-I$PREFIX/include" \
        LDFLAGS="-L$PREFIX/lib"
fi

echo "==> build aria2c.exe"
make -j"$JOBS" >/dev/null

mkdir -p "$OUT_DIR"
cp src/aria2c.exe "$OUT_DIR/"
"$STRIP" "$OUT_DIR/aria2c.exe" || true

echo "==> $OUT_DIR/aria2c.exe"
ls -la "$OUT_DIR/aria2c.exe"
file "$OUT_DIR/aria2c.exe" 2>/dev/null || true
