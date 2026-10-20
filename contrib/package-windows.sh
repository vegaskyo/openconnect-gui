#!/usr/bin/env bash
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo 'Use the MSYS2 MINGW64 environment' >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
export PATH="/mingw64/bin:/usr/bin:$PATH"
export OC_TAG=${OC_TAG:-$(tr -d '\r\n' < contrib/openconnect-version.txt)}
[[ $OC_TAG =~ ^(v[0-9]+\.[0-9]+(\.[0-9]+)?|master)$ ]] || { echo 'Invalid OpenConnect tag' >&2; exit 1; }
export BUILD_JOBS=${BUILD_JOBS:-4}
[[ $BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build job count' >&2; exit 1; }
mkdir -p build-output/windows build-output/logs
if [[ ${OCG_PACKAGES_READY:-0} != 1 ]]; then
    mapfile -t packages < <(tr -d '\r' < contrib/windows-packages.txt)
    pacman --needed --noconfirm -S "${packages[@]}" > build-output/logs/packages.log 2>&1 || {
        cat build-output/logs/packages.log >&2; exit 1;
    }
fi

runtime="external/openconnect-${OC_TAG}_MINGW64.zip"
devel="external/openconnect-devel-${OC_TAG}_MINGW64.zip"
marker="external/openconnect-${OC_TAG}_MINGW64.build-key"
key=$(bash contrib/windows-cache-key.sh)
valid_archive() {
    local archive=$1 expected actual
    [[ -f $archive && -f $archive.sha512 ]] || return 1
    expected=$(awk 'NR==1 {print $1}' "$archive.sha512")
    actual=$(sha512sum "$archive" | awk '{print $1}')
    [[ $expected == "$actual" ]]
}
if [[ $OC_TAG != master && ${REBUILD_CORE:-0} != 1 ]] &&
    valid_archive "$runtime" && valid_archive "$devel" &&
    { [[ ! -f $marker ]] || [[ $(cat "$marker") == "$key" ]]; }; then
    echo 'OpenConnect: verified dependency cache hit; skipping core build.'
else
    echo 'OpenConnect: building dependencies (first run or changed version/toolchain).'
    BUILD_DIR=build-MINGW64 bash contrib/build_deps_mingw@msys2.sh > build-output/logs/core.log 2>&1 || {
        tail -n 80 build-output/logs/core.log >&2; exit 1;
    }
    valid_archive "$runtime" && valid_archive "$devel"
    key=$(bash contrib/windows-cache-key.sh)
fi
printf '%s\n' "$key" > "$marker"

build="$root/build-MINGW64/openconnect-gui"
out="$root/build-output/windows"
launcher=()
if command -v ccache >/dev/null; then
    export CCACHE_DIR=${CCACHE_DIR:-$root/build-cache/ccache}
    export CCACHE_COMPILERCHECK=content
    ccache --max-size 1G
    launcher=(-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_ARGS=-DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi
cmake -S "$root" -B "$build" -G 'MinGW Makefiles' \
    -DCMAKE_BUILD_TYPE=Release "-Dopenconnect-TAG=$OC_TAG" \
    "-DCMAKE_RC_COMPILER=$(cygpath -m /mingw64/bin/windres.exe)" "${launcher[@]}"
cmake --build "$build" --parallel "$BUILD_JOBS"
cpack --config "$build/CPackConfig.cmake" -G NSIS -B "$out"
gui_version=$(sed -n 's/^#define PROJECT_VERSION "\(.*\)"$/\1/p' "$build/src/config.h" | tail -n1 | tr -d '\r')
core_version=$(sed -n 's/^Version: //p' "$build/external/lib/pkgconfig/openconnect.pc" | tr -d '\r')
stem="openconnect-gui-${gui_version//-/.}-oc-${core_version//-/.}-win64"
cpack --config "$build/CPackConfig.cmake" -G ZIP -B "$out" -D "CPACK_PACKAGE_FILE_NAME=$stem-portable"
for asset in "$out/$stem.exe" "$out/$stem-portable.zip"; do
    [[ -s $asset && -s $asset.sha512 ]]
done
{
    printf 'Source commit: '; git rev-parse HEAD
    printf 'GUI: %s\nOpenConnect: %s\nRequested tag: %s\n' "$gui_version" "$core_version" "$OC_TAG"
    pacman -Q | LC_ALL=C sort
} > "$out/build-info.txt"
command -v ccache >/dev/null && ccache --show-stats || true
printf '\nPackages ready: %s\n' "$(cygpath -w "$out")"
