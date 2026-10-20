#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tag=${OC_TAG:-$(tr -d '\r\n' < "$root/contrib/openconnect-version.txt")}
[[ $tag =~ ^(v[0-9]+\.[0-9]+(\.[0-9]+)?|master)$ ]] || { echo 'Invalid OpenConnect tag' >&2; exit 1; }
{
    printf '%s\n' "$tag" "$MSYSTEM"
    sha512sum "$root/contrib/build_deps_mingw@msys2.sh" "$root/contrib/windows-packages.txt" |
        awk '{print $1}'
    pacman -Q | LC_ALL=C sort | sed -n '/^mingw-w64-x86_64-/p'
} | sha512sum | cut -c1-32
