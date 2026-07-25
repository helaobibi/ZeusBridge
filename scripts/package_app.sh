#!/usr/bin/env bash
# Package SwiftPM release binary into dist/ + optional .app wrapper.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/ZeusBridge.app"
BIN_NAME="ZeusBridge"

# Locate release binary (SwiftPM layout)
CANDIDATES=(
	"$ROOT/.build/release/${BIN_NAME}"
	"$ROOT/.build/arm64-apple-macosx/release/${BIN_NAME}"
	"$ROOT/.build/x86_64-apple-macosx/release/${BIN_NAME}"
)

BIN=""
for c in "${CANDIDATES[@]}"; do
	if [[ -x "$c" ]]; then
		BIN="$c"
		break
	fi
done

if [[ -z "$BIN" ]]; then
	# Fallback: ask swift build for bin path
	if command -v swift >/dev/null 2>&1; then
		BIN="$(swift build -c release --show-bin-path 2>/dev/null)/${BIN_NAME}" || true
	fi
fi

if [[ -z "${BIN}" || ! -x "${BIN}" ]]; then
	echo "error: release binary not found. Run: swift build -c release" >&2
	echo "searched:" >&2
	printf '  %s\n' "${CANDIDATES[@]}" >&2
	exit 1
fi

echo "using binary: $BIN"
rm -rf "$DIST"
mkdir -p "$DIST"

# 1) Bare binary copy
cp -f "$BIN" "$DIST/zeus-bridge"
chmod +x "$DIST/zeus-bridge"
cp -f "$BIN" "$DIST/${BIN_NAME}"
chmod +x "$DIST/${BIN_NAME}"

# 2) .app bundle (better for TCC permission entries)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/${BIN_NAME}"
chmod +x "$APP/Contents/MacOS/${BIN_NAME}"
cp -f "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign (no Developer ID required)
if command -v codesign >/dev/null 2>&1; then
	codesign --force --deep -s - "$APP" 2>/dev/null || true
	codesign --force -s - "$DIST/zeus-bridge" 2>/dev/null || true
	codesign --force -s - "$DIST/${BIN_NAME}" 2>/dev/null || true
fi

# Usage note
cat > "$DIST/README-USAGE.txt" <<'EOF'
ZeusBridge (macOS)

1. Remove quarantine (if Gatekeeper blocks):
   xattr -dr com.apple.quarantine ZeusBridge.app
   xattr -dr com.apple.quarantine zeus-bridge

2. Permissions:
   System Settings → Privacy & Security
   - Screen Recording: enable ZeusBridge
   - Accessibility: enable ZeusBridge

3. Run dry-run first:
   ./ZeusBridge.app/Contents/MacOS/ZeusBridge --dry-run -v
   # or
   ./zeus-bridge --list-windows
   ./zeus-bridge --dry-run

4. Start WoW windowed, load addon, then drop --dry-run.
EOF

echo "packaged → $DIST"
ls -la "$DIST"
ls -la "$APP/Contents/MacOS" || true
