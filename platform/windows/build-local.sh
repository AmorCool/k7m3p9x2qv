#!/usr/bin/env bash
#
# aria2 for Windows, built natively inside MSYS2.
#
# This is the companion to platform/windows/build.sh, not a replacement for it.
# build.sh cross-compiles from Linux with `--host=x86_64-w64-mingw32`, which is
# what CI runs; this one compiles on the machine it will run on, with the
# mingw-w64 toolchain that MSYS2's MINGW64/MINGW32 shell already puts on PATH.
#
# The difference that matters is what `--host` means:
#
#   * On a Linux cross-build, the compiler is named `x86_64-w64-mingw32-gcc`
#     and `--host` is what tells configure it is not targeting the build
#     machine. Without it, configure would try to *run* the PE test programs
#     it links and fail.
#   * Under MSYS2, `gcc` is already `x86_64-w64-mingw32-gcc`. Configuring with
#     a `--host` equal to the build machine makes autoconf think it is a
#     native build anyway, so the flag buys nothing and passing a mismatched
#     one only invites trouble. It is omitted here and `config.guess` decides.
#
# Dependencies are NOT built from source here, unlike build.sh. MSYS2 ships
# every one of them as a package that contains a static archive next to the
# import library, and using those turns a multi-hour build into a few minutes.
# The archives are load bearing: a plain `-lz` on mingw resolves to
# `libz.dll.a` before `libz.a`, so the binary would come out depending on
# `zlib1.dll` and seven of its friends. `-static` in LDFLAGS is what makes the
# linker take the archives, and the verification step below prints the import
# table so that a regression is visible rather than discovered on a user's
# machine.
#
# Because the packages track current upstream rather than the versions pinned
# in `dependences`, this build is for local development and for checking a
# patch. The reproducible, pinned build is the CI one. OpenSSL in particular is
# 3.x here against 1.1.1k there.
#
# Usage, from an MSYS2 "MINGW64" or "MINGW32" shell:
#
#   platform/windows/build-local.sh              # 64-bit
#   platform/windows/build-local.sh --clean      # discard build/ and rebuild
#
# Output: build/local-windows/<arch>/aria2c.exe
#
# Licence: GPLv3. See LICENSE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARIA2_VERSION="${ARIA2_VERSION:-1.37.0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        # Print the header comment, up to the first line of code.
        -h|--help) awk 'NR>2 && /^set -euo/{exit} NR>2{print}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Refuse to run anywhere but an MSYS2 mingw shell.
#
# A plain "MSYS" shell has gcc too, but it is `x86_64-pc-msys`: it produces
# binaries that link against msys-2.0.dll and cannot be shipped. Catching it
# here is worth the four lines, because the failure it otherwise causes is a
# link error hundreds of lines into the build that names no cause.
# ---------------------------------------------------------------------------
for tool in gcc g++ make pkg-config patch curl tar strip objdump; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not found on PATH." >&2
        echo "       Run this from an MSYS2 'MINGW64' (or 'MINGW32') shell." >&2
        exit 1
    }
done

TOOLCHAIN_TRIPLE="$(gcc -dumpmachine)"
case "$TOOLCHAIN_TRIPLE" in
    x86_64-w64-mingw32) ARCH="x64" ;;
    i686-w64-mingw32)   ARCH="x86" ;;
    *)
        echo "error: this is not a mingw-w64 toolchain (gcc -dumpmachine = $TOOLCHAIN_TRIPLE)." >&2
        echo "       Open the MSYS2 'MINGW64' shell (or 'MINGW32' for 32-bit) and rerun." >&2
        exit 1
        ;;
esac

MINGW_PREFIX="${MINGW_PACKAGE_PREFIX:-}"
if [ -z "$MINGW_PREFIX" ]; then
    case "$ARCH" in
        x64) MINGW_PREFIX="mingw-w64-x86_64" ;;
        x86) MINGW_PREFIX="mingw-w64-i686" ;;
    esac
fi

BUILD_ROOT="$ROOT_DIR/build/local-windows/$ARCH"
ARIA2_SRC="$BUILD_ROOT/aria2"
PREFIX="$BUILD_ROOT/prefix"
OUT_DIR="$BUILD_ROOT"

if [ "$CLEAN" = "1" ]; then
    echo "==> --clean: removing $BUILD_ROOT"
    rm -rf "$BUILD_ROOT"
fi

echo "==> aria2 $ARIA2_VERSION, native MSYS2 build for Windows ($ARCH, $TOOLCHAIN_TRIPLE)"

# ---------------------------------------------------------------------------
# Dependencies: MSYS2 packages, each checked for the static archive.
#
# The check is per library rather than per package on purpose. A package that
# is installed but has been built shared-only would pass a `pacman -Q` test and
# fail the link with `undefined reference`, which reads like a source problem.
# Naming the missing archive and the exact package to install is what keeps
# this a one-line fix.
# ---------------------------------------------------------------------------
MISSING_PKGS=()
MISSING_LIBS=()

need_lib() {
    local module="$1" libname="$2" package="$3"
    if ! pkg-config --exists "$module"; then
        MISSING_PKGS+=("$package")
        return
    fi
    local libdir
    libdir="$(pkg-config --variable=libdir "$module")"
    if [ ! -f "$libdir/$libname" ]; then
        MISSING_LIBS+=("$libdir/$libname (from $package)")
    fi
}

need_lib zlib      libz.a        "$MINGW_PREFIX-zlib"
need_lib expat     libexpat.a    "$MINGW_PREFIX-expat"
need_lib sqlite3   libsqlite3.a  "$MINGW_PREFIX-sqlite3"
need_lib libcares  libcares.a    "$MINGW_PREFIX-c-ares"
need_lib libssh2   libssh2.a     "$MINGW_PREFIX-libssh2"
need_lib openssl   libssl.a      "$MINGW_PREFIX-openssl"
need_lib openssl   libcrypto.a   "$MINGW_PREFIX-openssl"

if [ "${#MISSING_PKGS[@]}" -gt 0 ] || [ "${#MISSING_LIBS[@]}" -gt 0 ]; then
    echo "error: the MSYS2 dependencies this build needs are not all present." >&2
    if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        echo "       not installed: ${MISSING_PKGS[*]}" >&2
    fi
    if [ "${#MISSING_LIBS[@]}" -gt 0 ]; then
        echo "       installed but without a static archive:" >&2
        for entry in "${MISSING_LIBS[@]}"; do echo "         $entry" >&2; done
    fi
    echo "       install with:" >&2
    echo "         pacman -S --needed ${MISSING_PKGS[*]:-<the packages listed above>}" >&2
    exit 1
fi

echo "==> dependencies: $(pkg-config --modversion zlib) zlib, $(pkg-config --modversion expat) expat, $(pkg-config --modversion sqlite3) sqlite3, $(pkg-config --modversion libcares) c-ares, $(pkg-config --modversion libssh2) libssh2, $(pkg-config --modversion openssl) openssl"

# ---------------------------------------------------------------------------
# aria2: fetch and patch through the shared script, so this build applies the
# same four Turbo patches as every other target and cannot drift from them.
# ---------------------------------------------------------------------------
"$ROOT_DIR/scripts/fetch-and-patch.sh" "$ARIA2_VERSION" "$ARIA2_SRC"
cd "$ARIA2_SRC"

# Configure, natively.
#
# No --host and no --build: both default to the machine config.guess describes,
# which is the mingw target itself.
#
# ARIA2_STATIC=yes does two things inside configure.ac: it appends --static to
# PKG_CONFIG, so the Libs.private entries (-lws2_32, -lcrypt32 and the rest of
# OpenSSL's Win32 baggage) are pulled in, and on i686 it defines
# _USE_32BIT_TIME_T, which the 32-bit mingw runtime needs because it does not
# implement the 64-bit time functions.
#
# LDFLAGS=-static is the flag that actually selects the .a archives. Without it
# the linker prefers each package's lib<name>.dll.a and the executable ends up
# importing zlib1.dll, libcrypto-3-x64.dll and so on.
#
# --with-ca-bundle matches build.sh. It is compiled in, not read at runtime, so
# the two builds look for the CA bundle in the same place.
CA_BUNDLE="C:/ProgramData/aria2/ca-bundle.crt"

if [ ! -f .configured ]; then
    ./configure \
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
        LDFLAGS="-static"
    touch .configured
else
    echo "==> already configured, reusing (rm $ARIA2_SRC/.configured to redo)"
fi

echo "==> build aria2c.exe"
make -j"$JOBS"

mkdir -p "$OUT_DIR"
cp src/aria2c.exe "$OUT_DIR/"
strip "$OUT_DIR/aria2c.exe" || true

# ---------------------------------------------------------------------------
# Verify: the binary is a PE for this machine, it imports nothing but the
# Windows system DLLs, and the Turbo options are compiled in.
#
# The import check is the one that cannot be skipped. A build that links
# against MSYS2's shared libraries succeeds, runs on this machine, and fails
# on any machine without MSYS2 installed -- which is every machine that would
# receive the file. Only the import table distinguishes the two.
# ---------------------------------------------------------------------------
# Note on style below: every match is fed to grep through a here-string rather
# than a pipe. `echo "$HELP" | grep -q PATTERN` looks equivalent and is not --
# grep -q exits at the first match, the writer is left holding a closed pipe,
# and under `set -o pipefail` the pipeline reports 141 (SIGPIPE) even though
# grep succeeded. That is a "the option is missing" verdict for a binary that
# has it, which is exactly what this step is supposed to rule out.
echo "==> verify"
EXE="$OUT_DIR/aria2c.exe"
FILE_OUT="$(file "$EXE")"
echo "    $FILE_OUT"
if ! grep -q 'PE32' <<< "$FILE_OUT"; then
    echo "error: not a PE binary" >&2
    exit 1
fi

IMPORTS="$(objdump -p "$EXE" | awk '/DLL Name:/ {print $3}' | sort -u)"
echo "    imports: $(tr '\n' ' ' <<< "$IMPORTS")"
UNEXPECTED="$(grep -viE '^(KERNEL32|msvcrt|api-ms-win-|ADVAPI32|WS2_32|WSOCK32|GDI32|WINMM|IPHLPAPI|PSAPI|CRYPT32|USER32|bcrypt|NTDLL|SHELL32|ole32|USERENV|DNSAPI|SECUR32|OLEAUT32|VERSION|NETAPI32|SHLWAPI|COMDLG32|Normaliz)\.dll$' <<< "$IMPORTS" || true)"
if [ -n "$UNEXPECTED" ]; then
    echo "error: the executable imports non-system libraries:" >&2
    echo "$UNEXPECTED" | sed 's/^/         /' >&2
    echo "       it was linked against MSYS2's shared libraries; the -static" >&2
    echo "       LDFLAGS did not take effect." >&2
    exit 1
fi

# --help is generated from the option table, so a patch that failed to apply
# shows up as a missing line.
VERSION_OUT="$("$EXE" --version)"
echo "    $(head -n1 <<< "$VERSION_OUT")"
HELP="$("$EXE" --help=#all)"

if ! grep -q 'retry-on-400' <<< "$HELP"; then
    echo "error: --retry-on-400 missing (patch 0003 not applied)" >&2
    exit 1
fi
if ! grep -q 'max-connection-per-server' <<< "$HELP"; then
    echo "error: max-connection-per-server missing" >&2
    exit 1
fi

# The name check above only proves the option exists upstream. 0001 is what
# changes the ceiling, from 16 to -1, so the range printed under the option is
# the thing that proves the patch landed: "Possible Values: 1-*".
RANGE="$(awk '/-x, --max-connection-per-server=/{found=1} found && /Possible Values:/{print $3; exit}' <<< "$HELP")"
if [ "$RANGE" != "1-*" ]; then
    echo "error: max-connection-per-server allows '$RANGE', expected '1-*' (patch 0001 not applied)" >&2
    exit 1
fi
echo "    max-connection-per-server: Possible Values: $RANGE"

echo "==> $EXE"
ls -la "$EXE"
