@echo off
rem ---------------------------------------------------------------------------
rem Launcher for platform/windows/build-local.sh.
rem
rem Not required -- the script runs fine from an MSYS2 MINGW64 shell directly.
rem This exists so the build can be started from a plain cmd.exe or by
rem double-clicking, without the user having to know that MSYS2 needs a
rem particular shell (MINGW64, not MSYS) to get the mingw-w64 gcc on PATH.
rem
rem MSYSTEM and CHERE_INVOKING are what make the login shell behave: MSYSTEM
rem selects the mingw64 toolchain in /etc/profile, and CHERE_INVOKING stops it
rem from cd'ing to $HOME so the relative script path below resolves.
rem
rem Override the install location with:  set MSYS2_ROOT=D:\msys64
rem ---------------------------------------------------------------------------
setlocal

if "%MSYS2_ROOT%"=="" set "MSYS2_ROOT=C:\msys64"
if not exist "%MSYS2_ROOT%\usr\bin\bash.exe" (
    echo error: MSYS2 not found at "%MSYS2_ROOT%". 1>&2
    echo        Install it from https://www.msys2.org/ or set MSYS2_ROOT. 1>&2
    exit /b 1
)

set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"

cd /d "%~dp0..\.."

"%MSYS2_ROOT%\usr\bin\bash.exe" -lc "bash platform/windows/build-local.sh %*"
set "RC=%errorlevel%"

endlocal & exit /b %RC%
