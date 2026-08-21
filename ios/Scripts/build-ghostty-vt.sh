#!/bin/sh
set -eu

revision="9ae02a326f62bd88f7f5508cf1807c67e7775cb5"
checksum="8f751649e69b6d494a9087a56279683eded91347b97b170e1252800338378469"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root/Vendor/ghostty-vt.xcframework"

if [ -n "${GHOSTTY_SOURCE_DIR:-}" ]; then
    if ! command -v zig >/dev/null 2>&1; then
        echo "zig 0.16.0 or newer is required for a source build" >&2
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
