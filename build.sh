#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODULE="$ROOT/module"
DIST="$ROOT/dist"
VERSION=$(sed -n 's/^version=//p' "$MODULE/module.prop")

[ -n "$VERSION" ] || { echo "module.prop has no version" >&2; exit 1; }
command -v go >/dev/null || { echo "Go is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 1; }
command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 1; }
[ -x "$MODULE/bin/wireguard-go" ] || { echo "missing executable module/bin/wireguard-go" >&2; exit 1; }

TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
OUTPUT="$DIST/wireguard-server-ksu-v$VERSION.zip"

echo "Building Android arm64 controller binaries..."
(
  cd "$ROOT"
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$TEMP/wgctl" ./cmd/wgctl
  GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$TEMP/wgpanel" ./cmd/wgpanel
)
install -m 0755 "$TEMP/wgctl" "$MODULE/bin/wgctl"
install -m 0755 "$TEMP/wgpanel" "$MODULE/bin/wgpanel"

mkdir -p "$DIST"
rm -f "$OUTPUT"
echo "Packaging $OUTPUT..."
(
  cd "$MODULE"
  zip -r "$OUTPUT" . -x 'data/*' >/dev/null
)

echo "Verifying archive..."
unzip -t "$OUTPUT" >/dev/null
echo "Built $OUTPUT"
