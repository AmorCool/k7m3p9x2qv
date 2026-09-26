# aria2-cross

aria2 built for **Windows** and **iOS** from one patched source tree, with the
Linux builds kept from upstream.

Forked from [flyinbug/aria2-static-build](https://cnb.cool/flyinbug/aria2-static-build),
which is itself a fork of [P3TERX/Aria2-Pro-Core](https://github.com/P3TERX/Aria2-Pro-Core).

## What the patches do

The patches are the reason this fork exists. They are small, and they change
behaviour rather than just fixing a build:

| Patch | Change | Effect |
|---|---|---|
| `0001` | `max-connection-per-server` max `16` → `-1` | no cap on connections per server |
| `0001` | `min-split-size` min `1M` → `1K`, `piece-length` min `1M` → `1K` | much smaller segments, so more of them in flight |
| `0002` | three `DL_ABORT_EX` → `DL_RETRY_EX` | slow speed, dropped connection and TLS failure retry instead of aborting |
| `0003` | new `--retry-on-400/403/406/unknown` | 4xx responses can be retried |
| `0004` | `--no-want-digest-header` defaults to true | avoids servers that mishandle `Want-Digest` |

Together these are what upstream calls a "Turbo" build: raise the parallelism
ceiling, shrink the segment floor, and retry aggressively. They are the same
four patches the reference Turbo package applies, byte for byte.

There is a fifth patch in `patch/` that is **not** applied by default:

| Patch | Change | When |
|---|---|---|
| `0005` | `--split` default `5` → `32`, `--min-split-size` default `20M` → `1M` | only with `TURBO_DEFAULTS=1` |

The four that are always applied remove ceilings; `0005` moves defaults, which
is a behaviour change rather than a bug fix. The reference build leaves the
defaults alone, and a binary from here is supposed to behave like one from
there, so the change is opt-in:

```bash
TURBO_DEFAULTS=1 scripts/fetch-and-patch.sh 1.37.0 /tmp/aria2
```

With it on, a fresh install downloads in parallel without being configured
first. `max-connection-per-server` stays at 1 either way: it is a per-server
count, and defaulting it high means every ordinary download opens that many
sockets to one host whether or not it helps.

The patches are plain C++ edits with no platform assumptions, so all three
targets share them. Every build runs `scripts/fetch-and-patch.sh`, which
fetches the pinned aria2 release and applies them. Keeping the fetch and the
patch together is deliberate: a platform script that forgot one would still
produce a working binary that behaved differently from the others.

## Targets

| Target | How | Output |
|---|---|---|
| Windows x64 / x86 | mingw-w64 cross-compile on Linux | `build/windows/<arch>/aria2c.exe` |
| iOS device / simulator | Xcode toolchain on macOS | `build/ios/<sdk>/aria2c`, `libaria2.a` |
| Linux amd64 / arm64 / armhf / i386 | upstream scripts | `$HOME/output/aria2c` |

## Building

### Windows

Cross-compiled with mingw-w64, the same approach as the source tree's own
`Dockerfile.mingw`. Run on Linux with the toolchain installed:

```bash
sudo apt-get install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
    autoconf automake libtool pkg-config dpkg-dev xz-utils lzip bzip2

HOST=x86_64-w64-mingw32 ./platform/windows/build.sh   # 64-bit
HOST=i686-w64-mingw32   ./platform/windows/build.sh   # 32-bit
```

Three details come from upstream's `mingw-build-memo` and are easy to get
wrong: OpenSSL needs `--cross-compile-prefix` (a target name alone configures
cleanly and then fails to link), c-ares and libssh2 need `LIBS="-lws2_32"`
(Winsock), and libssh2 uses `--with-crypto=wincng` so it does not pull in a
second OpenSSL.

Upstream's `mingw-config` builds with `--without-openssl`, which leaves the
binary unable to fetch HTTPS. This fork needs HTTPS, so OpenSSL is built and
enabled. That is the one departure from their recipe.

jemalloc is skipped on Windows and on iOS. The reason is shared and is given
under iOS below: its symbol prefix, not a missing POSIX layer.

### iOS

Run on macOS. `xcrun` supplies clang, the linker and the SDK paths, so there is
no separate cross-toolchain to install.

```bash
./platform/ios/build.sh iphoneos          # device, arm64
./platform/ios/build.sh iphonesimulator   # simulator
```

Two outputs, for two integration styles:

- `aria2c` — a Mach-O executable. This is the one a client app wants: it runs
  the downloader as a child process, which keeps the GPL boundary at the
  process edge and lets the downloader die without taking the UI with it.
- `libaria2.a` — a static library, for linking aria2 into an app directly.

Deployment target follows the SDK on the machine, and `IPHONEOS_DEPLOYMENT_TARGET`
clamps it. The clamp matters: asking for 18.0 against an SDK of 17.5 does not
fail at configure time, it makes clang stop applying the sysroot, and the first
dependency that needs an SDK-only header dies with `'math.h' file not found`.
Most dependencies only include libc headers and keep working, so it surfaces
late and reads as a broken toolchain.

OpenSSL uses its `iphoneos-cross` preset with `no-asm`, because the perlasm
output is not compatible with the arm64 Darwin ABI.

jemalloc is not built here, nor on Windows, and the reason is not the POSIX
layer — iOS has one. jemalloc's configure picks a default symbol prefix from
the object format:

```
if abi != macho and abi != pecoff:  JEMALLOC_PREFIX=""     # exports malloc
else:                               JEMALLOC_PREFIX="je_"   # exports je_malloc
```

Only the unprefixed form is useful to aria2, which never calls a jemalloc
function — there is no reference to jemalloc anywhere under `src/`. It relies
on the linker resolving `malloc` to jemalloc's copy, and the prefix prevents
that. aria2 checks for exactly that form and fails configure without it:

```
configure: error: jemalloc (unprefixed) is requested but not found in the system.
```

Forcing an empty prefix would pass the check and is the wrong answer: the
prefix exists on these platforms so a bundled allocator does not displace the
system one, and replacing `malloc` on iOS is not supported.

Nine things about the iOS build are worth knowing before changing it:

- **No bitcode.** `-fembed-bitcode-marker` makes the linker believe
  `ENABLE_BITCODE` is on, which collides with OpenSSL's provider modules —
  those are built as loadable bundles — and the build dies at the last step
  with `-bundle and -bitcode_bundle cannot be used together`.
- **`--host` must say `ios`.** Autoconf decides it is cross-compiling by
  comparing `--host` against `--build`. Both are arm64 on an Apple Silicon
  runner, so if `--host` is `arm64-apple-darwin` the two compare equal and
  configure tries to *run* the Mach-O test programs. `--build` is therefore
  translated to the canonical `aarch64-apple-darwin`.
- **Old `config.sub` files.** Several dependencies ship one that predates
  arm64 Darwin and abort on `arm64-apple-ios`. The build refreshes them from
  the local automake, checking each candidate by running it rather than by
  looking at it.
- **sqlite's shell is not built.** It is in `bin_PROGRAMS`, calls `system()`,
  and `system()` is unavailable on iOS, so the default target fails and takes
  the library with it. The library target is built directly.
- **The deployment target must not exceed the SDK.** See above — the failure it
  causes names `math.h`, not the deployment target.
- **A build system that rewrites `CFLAGS` drops the sysroot.** jemalloc's
  configure assigns to `CFLAGS`, discarding the exported value, and its
  `*.sym.o` targets call `$(CC)` with no `CFLAGS` at all. For such a package
  the sysroot has to go into `CC`, where it is part of the command. This is
  recorded rather than fixed, because nothing here builds jemalloc now.
- **`PKG_CONFIG_LIBDIR`, not just `PKG_CONFIG_PATH`.** The first adds to
  pkg-config's search path, the second replaces it. With only the first, a
  runner that has Homebrew installed answers for OpenSSL with the host's copy:

  ```
  OpenSSL: yes (CFLAGS='-I/opt/homebrew/Cellar/openssl@3/3.6.3/include'
                  LIBS='-L/opt/homebrew/Cellar/openssl@3/3.6.3/lib -lssl -lcrypto')
  ```

  That is a macOS library. Setting both variables points pkg-config at
  `$PREFIX/lib/pkgconfig` and nowhere else, which is what a cross-build needs.
- **`-lrt` does not exist here.** aria2's `configure.ac` adds
  `-lpthread -ldl -lrt` for a static build on any host that is not mingw, msvc
  or darwin. `arm64-apple-ios` is none of those, so it took the Linux branch
  and the link failed with `ld: library 'rt' not found`. On iOS all three live
  in libSystem. `patch/platform/ios/` carries the fix, and it is kept out of
  the Turbo set so that the Windows and Linux binaries stay comparable with
  the reference build.
- **`Security.framework` is needed for one symbol.** `SimpleRandomizer.cc`
  selects its random source per platform, and the Apple branch calls
  `SecRandomCopyBytes(kSecRandomDefault, ...)`. Nothing else here pulls in
  Security, so the link ends with `_SecRandomCopyBytes` and `_kSecRandomDefault`
  undefined. It is added to aria2's `LDFLAGS` for that configure only, so the
  dependencies keep the flags they were built with.
- **Patch `configure`, not only `configure.ac`.** The release tarball ships
  `configure` already generated, and that generated file is what runs.
  Patching only `configure.ac` changes a file nothing reads, and the build
  fails in exactly the way the patch was meant to prevent — which is what
  happened here. Regenerating would need autoconf in the version the tree was
  built with; `fetch-and-patch.sh` patches the generated file directly and
  then touches the timestamps so make does not try to regenerate it either.

### Linux

Unchanged from upstream:

```bash
bash platform/linux/build-amd64.sh
bash platform/linux/build-arm64.sh
bash platform/linux/build-armhf.sh
bash platform/linux/build-i386.sh
```

## Layout

```
patch/                    the four Turbo patches
dependences               pinned dependency versions, shared by all targets
scripts/fetch-and-patch.sh   fetch aria2 + apply patches (shared)
snippet/                  upstream build helpers (shared by the Linux scripts)
platform/windows/build.sh
platform/ios/build.sh
platform/linux/build-*.sh
.github/workflows/build.yml
```

Every target builds its dependencies from source with `--enable-static
--disable-shared`, so the output has no runtime library dependency to ship
alongside it. That matters most on Windows, where the alternative is a
directory of DLLs next to the executable.

## CI

`build.yml` builds Windows (x64 and x86) and iOS (device and simulator). The
Windows job asserts that the output is a PE binary for the right machine and
that the patch-added option names are present in it, so a patch that silently
failed to apply is caught at build time rather than discovered as a
performance difference later.

The iOS job needs a macOS runner. It reads the label from the repository
variable `IOS_RUNNER`, falling back to `macos-14`, because the Xcode version
this project targets is not the one on the standard hosted image.

Binaries are delivered as **release assets**, one release per job, tagged
`build-<run>-<job>`. The workflow-artifact upload is best effort and cannot
fail the job. That is not a preference: the account's artifact quota filled up,
and the first Windows build that actually succeeded went red on the upload step
while its binary sat there verified and unshipped. Release assets have their
own quota and are what the consuming app downloads from.

Fetch a binary into an app with:

```bash
node scripts/fetch-engine.js          # current platform
node scripts/fetch-engine.js --list   # what is available
```

## Licence

GPLv3. See `LICENSE`.

aria2 is GPLv3 and so are the patches. Distributing a binary built here means
distributing the corresponding source — which is what this repository is,
patches included. OpenSSL is used under its linking exception as described in
aria2's own source headers.
