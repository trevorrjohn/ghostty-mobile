#!/bin/sh
set -eu

revision="0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec"
checksum="afe33857dc3dff90174efc76969be8d9e1ad20d6893861103c2afda23826f4f4"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root/Vendor/ghostty-vt.xcframework"

if [ -n "${GHOSTTY_SOURCE_DIR:-}" ]; then
    if ! command -v zig >/dev/null 2>&1; then
        echo "zig 0.17.0 or newer is required for a source build" >&2
        exit 1
    fi

    (cd "$GHOSTTY_SOURCE_DIR" && zig build -Demit-lib-vt -Doptimize=ReleaseFast)
    framework="$GHOSTTY_SOURCE_DIR/zig-out/lib/ghostty-vt.xcframework"
else
    temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-vt.XXXXXX")
    trap 'rm -rf "$temporary_dir"' EXIT
    archive="$temporary_dir/ghostty-vt.xcframework.zip"
    url="https://tip.files.ghostty.org/$revision/ghostty-vt.xcframework.zip"

    curl --fail --location --silent --show-error "$url" --output "$archive"
    printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
    ditto -x -k "$archive" "$temporary_dir"
    framework="$temporary_dir/ghostty-vt.xcframework"
fi

mkdir -p "$(dirname -- "$destination")"
rm -rf "$destination"
ditto "$framework" "$destination"

echo "Installed $destination"
