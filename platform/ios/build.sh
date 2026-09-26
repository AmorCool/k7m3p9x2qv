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
# Deployment target: the SDK's own version, so a dependency that needs an SDK
# header cannot be built against a sysroot clang has stopped applying. Set
# IPHONEOS_DEPLOYMENT_TARGET to lower it, or to raise it when the SDK allows.
#
# Licence: GPLv3. See LICENSE. Shipping the binary means shipping the source
# of this fork, including the patches, which is why they live in this repo.

set -euo pipefail

SDK="${1:-iphoneos}"                   # iphoneos | iphonesimulator
ARIA2_VERSION="${ARIA2_VERSION:-1.37.0}"
ARCH="${ARCH:-arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/ios/$SDK}"
ARIA2_SRC="$BUILD_ROOT/aria2"
PREFIX="$BUILD_ROOT/deps"
OUT_DIR="$BUILD_ROOT"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SDK_PATH="$(xcrun -sdk "$SDK" -show-sdk-path)"

# The deployment target is clamped to the SDK on the machine.
#
# Declaring 18.0 against an SDK of 17.5 is not a request that can be honoured,
# and it does not fail where it is written: clang accepts the flag and stops
# applying the sysroot, so the error surfaces later in whichever dependency
# first includes a header only the SDK provides. Clamping keeps the target
# satisfiable and the sysroot in force.
#
# This was originally written to explain a jemalloc failure reading
#
#     include/jemalloc/internal/jemalloc_internal_decls.h:4:10:
#         fatal error: 'math.h' file not found
#
# and it did not explain it -- the clamp was in place and the header was still
# missing. That cause is recorded with the dependency list below. The clamp is
# kept because a target ahead of the SDK is wrong on its own terms.
#
# The clamp uses the SDK's own major and minor versions, so a newer Xcode
# raises the target automatically. Set IPHONEOS_DEPLOYMENT_TARGET to override,
# and it is clamped too -- a caller who asks for more than the SDK offers gets
# the SDK, not a build that fails a dependency later.
read -r SDK_MAJOR SDK_MINOR <<<"$(basename "$SDK_PATH" | sed -nE 's/^[A-Za-z]+([0-9]+)\.([0-9]+).*/\1 \2/p')"
SDK_VERSION="${SDK_MAJOR:-17}.${SDK_MINOR:-0}"

requested_target="${IPHONEOS_DEPLOYMENT_TARGET:-$SDK_VERSION}"
# `sort -V` picks the lower of the two: the request when it is already
# satisfiable, the SDK when the request is ahead of it.
DEPLOYMENT_TARGET="$(printf '%s\n%s\n' "$requested_target" "$SDK_VERSION" | sort -V | head -1)"

CC_BIN="$(xcrun -sdk "$SDK" -f clang)"
CXX_BIN="$(xcrun -sdk "$SDK" -f clang++)"

export CC="$CC_BIN"
export CXX="$CXX_BIN"
export AR="$(xcrun -f ar)"
export RANLIB="$(xcrun -f ranlib)"
export STRIP="$(xcrun -f strip)"
export LIBTOOL="$(xcrun -f libtool)"

# -arch and the sysroot have to go through CFLAGS/CXXFLAGS rather than --host,
# because Apple's clang is not a target-triple compiler: a bare --host
# produces a triple that autoconf accepts but clang does not act on. Passing the
# flags explicitly is the supported way to cross-compile to iOS.
TRIPLE_CFLAGS="-arch $ARCH -isysroot $SDK_PATH"
case "$SDK" in
    iphoneos)        PLATFORM_FLAGS="-miphoneos-version-min=$DEPLOYMENT_TARGET" ;;
    iphonesimulator) PLATFORM_FLAGS="-mios-simulator-version-min=$DEPLOYMENT_TARGET" ;;
    *) echo "unknown sdk: $SDK" >&2; exit 1 ;;
esac

# No -fembed-bitcode. It is not needed for a static library, and the marker
# form makes the linker believe ENABLE_BITCODE is on, which collides with
# anything built as a loadable bundle:
#
#     ld: -bundle and -bitcode_bundle (Xcode setting ENABLE_BITCODE=YES)
#         cannot be used together
#
# That is exactly what OpenSSL's provider modules are, so the flag turned a
# library build into a link failure at the last step. Bitcode itself is
# deprecated from Xcode 14 onwards.
export CFLAGS="$TRIPLE_CFLAGS $PLATFORM_FLAGS -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$TRIPLE_CFLAGS $PLATFORM_FLAGS"

# pkg-config must see the dependencies built here, and only those.
#
# PKG_CONFIG_PATH alone is not enough. It adds to the default search path
# rather than replacing it, so on a runner that has Homebrew installed,
# pkg-config answers for OpenSSL with the host's copy:
#
#     OpenSSL: yes (CFLAGS='-I/opt/homebrew/Cellar/openssl@3/3.6.3/include'
#                     LIBS='-L/opt/homebrew/Cellar/openssl@3/3.6.3/lib
#                           -lssl -lcrypto')
#
# That is a macOS library. Linking an iOS binary against it either fails or
# produces one that cannot run, and neither says which library was wrong.
# PKG_CONFIG_LIBDIR replaces the default path, which is what excludes it.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# autoconf answers that must be supplied rather than detected.
#
# configure decides these by compiling a test program and running it, which
# cannot work here: the program is a Mach-O for a platform the build host will
# not execute. Without an answer configure reports "cannot run C compiled
# programs" and every check downstream fails, which reads as a broken
# toolchain rather than as an unanswered question.
#
# These are the standard cross-compiling answers and match what the SDK
# provides on iOS.
export ac_cv_exeext=""
export ac_cv_file__dev_zero="yes"
export ac_cv_func_setpgrp_void="yes"
export ac_cv_func_malloc_0_nonnull="yes"
export ac_cv_func_realloc_0_nonnull="yes"
export ac_cv_working_alloca_h="yes"
export ac_cv_func_getaddrinfo="yes"
export ac_cv_func_gethostbyname="yes"
export ac_cv_func_strcasecmp="yes"
export ac_cv_func_working_mktime="yes"
# The machine this runs on, for --build.
#
# Autoconf decides whether it is cross-compiling by comparing --build against
# --host, and if the two look alike it tries to *run* the test programs it has
# just compiled. Those programs are Mach-O output for an iPhone, so running them
# fails and configure reports
#
#     configure: error: cannot run C compiled programs
#
# which reads as a broken compiler rather than as a mismatched pair of triples.
#
# The value must therefore differ from "$ARCH-apple-ios". `uname -m` alone
# is not usable for this: on Apple Silicon it answers `arm64`, which is the same
# architecture the target uses, so the two triples compare equal and
# cross-compiling is switched off. Translating it to the canonical name gives
# `aarch64-apple-darwin`, which autoconf accepts and which is deliberately a
# different string from the --host value. Doing the translation here rather
# than shelling out to config.guess keeps it independent of whether automake
# has been installed yet.
case "$(uname -m)" in
    arm64)  BUILD_TRIPLE="aarch64-apple-darwin" ;;
    x86_64) BUILD_TRIPLE="x86_64-apple-darwin" ;;
    *)      BUILD_TRIPLE="$(uname -m)-apple-darwin" ;;
esac

echo "==> aria2 $ARIA2_VERSION for $SDK ($ARCH)"
echo "    sdk:        $SDK_PATH"
echo "    deploy:     $DEPLOYMENT_TARGET"

source "$ROOT_DIR/dependences"

# ---------------------------------------------------------------------------
# Dependencies
#
# Same versions as the Linux builds, except jemalloc.
#
# jemalloc is not built here, for the same reason it is not built on Windows.
# It is not a missing POSIX layer -- iOS has one. It is the symbol prefix.
#
# jemalloc's configure chooses a default prefix from the object format:
#
#     if abi != macho and abi != pecoff:  JEMALLOC_PREFIX=""
#     else:                               JEMALLOC_PREFIX="je_"
#
# so on Linux it exports `malloc` and on iOS and Windows it exports
# `je_malloc`. The unprefixed form is the one that matters: aria2 never calls
# a jemalloc function (there is no reference to jemalloc anywhere in src/), it
# relies on the linker resolving `malloc` to jemalloc's copy. With the prefix
# in place that never happens, and linking -ljemalloc produces a binary that
# allocates through libSystem while carrying jemalloc's code as dead weight.
#
# aria2 asks for the unprefixed form explicitly -- AC_CHECK_LIB([jemalloc],
# [malloc]) -- and fails configure when it is absent:
#
#     configure: error: jemalloc (unprefixed) is requested but not found
#
# Forcing an empty prefix would satisfy that check, and is the wrong answer:
# the prefix exists on these platforms precisely so that a bundled allocator
# does not displace the system one, and on iOS replacing malloc is not
# supported. The allocator is a performance choice, not a requirement, so it
# is dropped rather than forced.
#
# Two failures were found here before the prefix one, and both were the same
# mistake in different clothing, so they are worth stating:
#
#   * jemalloc's configure assigns to CFLAGS, discarding the exported value.
#     The -isysroot from this script never reached its compile lines, and the
#     missing math.h above was read as a broken toolchain. Any build system
#     that rewrites CFLAGS needs the sysroot in CC instead, where it is part
#     of the command and cannot be dropped.
#   * Its symbol-renaming targets (`*.sym.o`) invoke `$(CC)` with no CFLAGS at
#     all, which is the same problem for the same files.
#
# Both are moot while jemalloc is not built. They are recorded for whoever
# finds a reason to add it back.
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

# Point a dependency at a current config.sub/config.guess.
#
# Tarballs carry whatever config.sub their release was cut with, and the older
# ones do not know every arm64 Darwin triple -- sqlite3's is old enough to
# abort before it does anything else:
#
#     configure: error: /bin/sh ./config.sub arm64-apple-ios failed
#
# before it does anything else. Refreshing the two helpers is the supported way
# out and is cheaper than pinning a host triple the tree predates: the copy
# that ships with the local automake knows every triple the local autoconf can
# emit. Missing candidates are skipped rather than treated as an error, because
# not every host packages them in the same place.
refresh_config_helpers() {
    local dir="$1" helper source
    # Homebrew is the normal source on a macOS runner, and it is not always at
    # the same prefix, so ask it rather than assume /opt/homebrew.
    local brew_prefix=""
    if command -v brew >/dev/null 2>&1; then
        brew_prefix="$(brew --prefix 2>/dev/null)"
    fi

    for helper in config.sub config.guess; do
        [ -f "$dir/$helper" ] || continue
        for source in \
            ${brew_prefix:+"$brew_prefix"/share/automake*/"$helper"} \
            /opt/homebrew/share/automake*/"$helper" \
            /usr/local/share/automake*/"$helper" \
            /usr/share/automake*/"$helper"
        do
            [ -f "$source" ] || continue
            # config.sub is validated by running it: it has to be able to
            # normalise the triple we are about to pass, and an old copy
            # demonstrably cannot. That is the whole point of replacing it, so
            # it is also the right test.
            #
            # config.guess is not validated this way and does not need to be.
            # It ignores its arguments and prints the machine it runs on, so
            # it cannot be asked the question and is never the problem --
            # whatever copy the runner has answers correctly for the runner.
            case "$helper" in
                config.sub)
                    sh "$source" "$ARCH-apple-ios" >/dev/null 2>&1 || continue
                    ;;
            esac
            cp "$source" "$dir/$helper"
            chmod +x "$dir/$helper"
            break
        done
    done
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
    refresh_config_helpers "$BUILD_ROOT/expat"
    ./configure --host="$ARCH-apple-ios" --build="$BUILD_TRIPLE" --prefix="$PREFIX" \
        --enable-static --disable-shared --without-examples --without-tests \
        --without-docbook
    touch .configured
fi
do_build expat

mkdir -p "$BUILD_ROOT/c-ares" && cd "$BUILD_ROOT/c-ares"
fetch "$BUILD_ROOT/c-ares" "$C_ARES"
if [ ! -f .configured ]; then
    refresh_config_helpers "$BUILD_ROOT/c-ares"
    ./configure --host="$ARCH-apple-ios" --build="$BUILD_TRIPLE" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-tests
    touch .configured
fi
do_build c-ares

# OpenSSL for iOS.
#
# Version 3.3.x rather than the 1.1.1 the other targets use. 1.1.1 is
# end-of-life, and its perlasm output does not build for arm64 Darwin without
# the `no-asm` workaround; 3.x handles the platform better and is what an
# iOS project on this toolchain is already using, so the flags below are the
# ones known to work rather than ones inferred.
#
# `iphoneos-cross` is the preset that knows the iOS SDK layout, and it reads
# CROSS_TOP/CROSS_SDK/CROSS_COMPILE from the environment. `no-asm` is kept
# because it is the setting that has been exercised.
#
# `iossimulator-xcrun` is the matching preset for the simulator SDK.
OPENSSL_IOS="${OPENSSL_IOS:-https://www.openssl.org/source/openssl-3.3.2.tar.gz}"

mkdir -p "$BUILD_ROOT/openssl" && cd "$BUILD_ROOT/openssl"
fetch "$BUILD_ROOT/openssl" "$OPENSSL_IOS"
if [ ! -f .configured ]; then
    CROSS_TOP="$(dirname "$(dirname "$SDK_PATH")")"
    CROSS_SDK="$(basename "$SDK_PATH")"
    export CROSS_TOP CROSS_SDK
    export CROSS_COMPILE=""
    if [ "$SDK" = "iphoneos" ]; then
        ./Configure iphoneos-cross no-asm no-shared no-tests no-docs no-module \
            -DL_ENDIAN --prefix="$PREFIX"
    else
        ./Configure iossimulator-xcrun no-asm no-shared no-tests no-docs no-module \
            -DL_ENDIAN --prefix="$PREFIX"
    fi
    touch .configured
fi
echo "==> build openssl"
# `build_libs` is the OpenSSL 3.x target that builds libcrypto and libssl.
#
# It is paired with `no-module` because the providers are built as loadable
# bundles (`.dylib`), and a bundle cannot be linked on this toolchain -- it
# fails with "-bundle and -bitcode_bundle cannot be used together" and takes
# the whole build with it. The static libraries aria2 links against do not
# need the providers, and `no-module` is the supported way to leave them out.
make -j"$JOBS" build_libs >/dev/null
make install_sw >/dev/null

mkdir -p "$BUILD_ROOT/sqlite3" && cd "$BUILD_ROOT/sqlite3"
fetch "$BUILD_ROOT/sqlite3" "$SQLITE3"
if [ ! -f .configured ]; then
    refresh_config_helpers "$BUILD_ROOT/sqlite3"
    ./configure --host="$ARCH-apple-ios" --build="$BUILD_TRIPLE" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-dynamic-extensions
    touch .configured
fi

# Built and installed by target rather than with `make install`.
#
# sqlite's Makefile lists the command-line shell under bin_PROGRAMS, so the
# default target builds it, and shell.c calls system() -- which the iOS SDK
# marks unavailable:
#
#     shell.c:12309:8: error: 'system' is unavailable: not available on iOS
#     make: *** [sqlite3-shell.o] Error 1
#
# and takes the library down with it. It cannot be switched off: the shell is
# unconditional in the generated Makefile, and --enable-static-shell controls
# only whether the shell links the library statically.
#
# The three install targets below are exactly the library, the header and the
# pkg-config file. Naming them is more reliable than copying by hand, because
# the library is a libtool target and libtool keeps the real archive in
# `.libs/` -- a hand-written `cp libsqlite3.a` fails with "No such file or
# directory" even though the build succeeded.
echo "==> build sqlite3 (library only)"
make -j"$JOBS" libsqlite3.la >/dev/null
make install-libLTLIBRARIES install-includeHEADERS install-pkgconfigDATA >/dev/null

mkdir -p "$BUILD_ROOT/libssh2" && cd "$BUILD_ROOT/libssh2"
fetch "$BUILD_ROOT/libssh2" "$LIBSSH2"
if [ ! -f .configured ]; then
    # --with-openssl rather than the --with-crypto=wincng the Windows build
    # uses: wincng routes libssh2 through the Windows crypto API, which does
    # not exist here. Picking it explicitly avoids libssh2 selecting a backend
    # by sniffing the host and getting it wrong during a cross-compile.
    refresh_config_helpers "$BUILD_ROOT/libssh2"
    ./configure --host="$ARCH-apple-ios" --build="$BUILD_TRIPLE" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-examples-build \
        --with-openssl
    touch .configured
fi
do_build libssh2

# jemalloc has no usable form here; see the note above the dependency list.
echo "==> skipping jemalloc (the unprefixed allocator is unavailable on macho)"

# ---------------------------------------------------------------------------
# aria2
# ---------------------------------------------------------------------------

# The third argument is the iOS-specific patch set. See fetch-and-patch.sh for
# why these are kept apart from the Turbo patches.
"$ROOT_DIR/scripts/fetch-and-patch.sh" "$ARIA2_VERSION" "$ARIA2_SRC" "$ROOT_DIR/patch/platform/ios"
cd "$ARIA2_SRC"

# The ca-bundle path is baked in at configure time on iOS as elsewhere. There
# is no system store to point at, so it names the copy the app ships.
CA_BUNDLE="/usr/share/aria2/ca-bundle.crt"

if [ ! -f .configured ]; then
    refresh_config_helpers "$ARIA2_SRC"

    # Security.framework, for the one symbol that needs it.
    #
    # SimpleRandomizer.cc picks its random source by platform, and the Apple
    # branch calls SecRandomCopyBytes with kSecRandomDefault:
    #
    #     #elif defined(__APPLE__)
    #       auto rv = SecRandomCopyBytes(kSecRandomDefault, len, buf);
    #
    # Both live in Security.framework, and nothing else here pulls it in, so
    # the link ends with
    #
    #     "_SecRandomCopyBytes", referenced from:
    #         aria2::SimpleRandomizer::getRandomBytes(unsigned char*, unsigned long)
    #     "_kSecRandomDefault", referenced from:
    #         aria2::SimpleRandomizer::getRandomBytes(unsigned char*, unsigned long)
    #
    # Assigned per-command so the dependencies keep the LDFLAGS they were
    # configured with; only aria2 links against Security.
    #
    # The flag is spelled -Wl,-framework,Security rather than -framework
    # Security, and that spelling is the whole fix. Both reach the libtool
    # link line; only one of them survives it.
    #
    # GNU libtool records a framework for a Darwin host and for no other. From
    # ltmain.sh, in the argument loop:
    #
    #     framework)
    #       case $host in
    #         *-*-darwin*)
    #           case "$deplibs " in
    #             *" $qarg.ltframework "*) ;;
    #             *) func_append deplibs " $qarg.ltframework"
    #
    # This build's host is arm64-apple-ios, which does not match *-*-darwin*,
    # so the case body is skipped, `prev=` follows, and the argument is
    # dropped on the floor. Nothing reaches deplibs, nothing reaches
    # compile_command, and no warning is printed. "-framework Security" is
    # removed from the link silently -- which is why configure recorded it,
    # the summary printed it, and the link command contains no trace of it.
    #
    # -Wl,* takes a different path out of the same loop. It is split on commas
    # and rebuilt into the loop's own $arg, and $arg is appended to
    # compile_command unconditionally, without consulting $host:
    #
    #     -Wl,*)
    #       func_stripname '-Wl,' '' "$arg"
    #       ... for flag in $args; do func_append arg " $wl$func_quote_arg_result"
    #     ...
    #     if test -n "$arg"; then ... func_append compile_command " $arg"
    #
    # So this arrives at the link as -Wl,-framework -Wl,Security, and clang
    # hands "-framework Security" to ld.
    #
    # -all-static is not involved, though it looks like it should be: it is
    # libtool's own flag and it is set for this build. It does nothing here.
    # -all-static appends $link_static_flag, that variable is initialised from
    # lt_prog_compiler_static, and libtool.m4 clears it when the check that it
    # works fails:
    #
    #     _LT_LINKER_OPTION([if $compiler static flag $lt_tmp_static_flag works],
    #       ..., $lt_tmp_static_flag, [],
    #       [_LT_TAGVAR(lt_prog_compiler_static, $1)=])
    #
    # Configure logged that failure --
    #
    #     checking if ... clang++ ... static flag -static works... no
    #
    # -- so the variable is empty, -all-static expands to nothing, and
    # removing it would change nothing.
    LIBS="-Wl,-framework,Security" ./configure \
        --host="$ARCH-apple-ios" --build="$BUILD_TRIPLE" \
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
        --without-jemalloc \
        --with-ca-bundle="$CA_BUNDLE" \
        ARIA2_STATIC=yes \
        --disable-shared \
        --enable-static
    touch .configured
fi

echo "==> build aria2c"
# V=1, and no redirect to /dev/null.
#
# Automake's silent rules print "CXXLD aria2c" and nothing else, so a link
# failure arrives without the command that produced it. That is how a missing
# "-framework Security" was diagnosed twice from the error text alone, with
# the link line itself unreadable. V=1 puts the real command in the log, which
# is where the next one of these should be read rather than reconstructed.
make V=1 -j"$JOBS"

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
