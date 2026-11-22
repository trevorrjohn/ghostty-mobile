#!/bin/sh
set -eu

revision="6d244209978e599277904ff3ced7b8a2ebcc528d"
checksum="ea154c31fd04e43b1dab5f04596a757f403d566f0d014d2c5ba5ef315a4d52ec"
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
