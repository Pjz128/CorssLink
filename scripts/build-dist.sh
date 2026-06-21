#!/usr/bin/env bash
# CrossLink Distribution Builder with Version Management
# Prerequisites: Go, Flutter, zip (or PowerShell fallback)
# Usage: bash scripts/build-dist.sh [version]
#   If version is not specified, reads from VERSION file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/poc/relay/dist"

# Read version
VERSION="${1:-$(cat "$ROOT/VERSION" 2>/dev/null || echo '0.0.0')}"
RELEASE_DIR="$DIST/releases/v${VERSION}"

echo "=== CrossLink Distribution Builder v${VERSION} ==="
echo ""

# Create versioned release directory
mkdir -p "$RELEASE_DIR/windows" "$RELEASE_DIR/android"

# 1. Build Windows Agent
echo "[1/5] Building Windows agent (GOOS=windows)..."
cd "$ROOT/poc"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
GOOS=windows GOARCH=amd64 go build -o /tmp/ollama-agent.exe ./ollama-agent/
echo "       ollama-agent.exe built ($(du -h /tmp/ollama-agent.exe 2>/dev/null | cut -f1 || stat -c%s /tmp/ollama-agent.exe))"

# 2. Zip Windows distribution
echo "[2/5] Packaging Windows zip..."
cp /tmp/ollama-agent.exe "$RELEASE_DIR/windows/"
cp "$DIST/windows/start.bat" "$RELEASE_DIR/windows/"
cd "$RELEASE_DIR/windows"
if command -v zip &>/dev/null; then
  zip -j crosslink-agent.zip ollama-agent.exe start.bat
elif command -v powershell &>/dev/null; then
  powershell -Command "Compress-Archive -Path ollama-agent.exe,start.bat -DestinationPath crosslink-agent.zip -Force"
else
  echo "ERROR: Neither zip nor powershell found"
  exit 1
fi
rm -f ollama-agent.exe
ZIP_SIZE=$(stat -c%s crosslink-agent.zip 2>/dev/null || echo 0)
echo "       crosslink-agent.zip: $((ZIP_SIZE/1024))KB"

# 3. Build Flutter APK
echo "[3/5] Building Flutter APK..."
cd "$ROOT/app"
if command -v flutter &>/dev/null; then
  flutter build apk --release 2>&1 | tail -3 || flutter build apk --debug 2>&1 | tail -3
  APK_SRC=$(find build/app/outputs/flutter-apk -name "*.apk" 2>/dev/null | head -1)
  if [ -n "$APK_SRC" ]; then
    cp "$APK_SRC" "$RELEASE_DIR/android/crosslink.apk"
    APK_SIZE=$(stat -c%s "$RELEASE_DIR/android/crosslink.apk" 2>/dev/null || echo 0)
    echo "       crosslink.apk: $((APK_SIZE/1024/1024))MB"
  fi
else
  echo "       WARNING: flutter not found, skipping APK"
fi

# 4. Compute checksums
echo "[4/5] Computing checksums..."
cd "$RELEASE_DIR"
ZIP_SHA256=""
APK_SHA256=""
if command -v sha256sum &>/dev/null; then
  [ -f windows/crosslink-agent.zip ] && ZIP_SHA256=$(sha256sum windows/crosslink-agent.zip | cut -d' ' -f1)
  [ -f android/crosslink.apk ] && APK_SHA256=$(sha256sum android/crosslink.apk | cut -d' ' -f1)
elif command -v shasum &>/dev/null; then
  [ -f windows/crosslink-agent.zip ] && ZIP_SHA256=$(shasum -a 256 windows/crosslink-agent.zip | cut -d' ' -f1)
fi

# 5. Update manifest
echo "[5/5] Updating manifest..."
cd "$ROOT/poc"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Write versioned manifest
cat > "$RELEASE_DIR/manifest.json" << EOF
{
  "version": "${VERSION}",
  "updatedAt": "${TIMESTAMP}",
  "platforms": {
    "windows": {
      "label": "Windows Agent",
      "description": "AI Agent for Windows PC",
      "files": [
        {
          "name": "crosslink-agent.zip",
          "size": ${ZIP_SIZE:-0},
          "sha256": "${ZIP_SHA256:-}",
          "description": "ollama-agent + launcher script"
        }
      ]
    },
    "android": {
      "label": "Android APK",
      "description": "CrossLink mobile client",
      "files": [
        {
          "name": "crosslink.apk",
          "size": ${APK_SIZE:-0},
          "sha256": "${APK_SHA256:-}",
          "description": "CrossLink Flutter App"
        }
      ]
    }
  }
}
EOF

# Update current symlink for relay serving
rm -f "$DIST/current"
ln -sf "releases/v${VERSION}" "$DIST/current" 2>/dev/null || {
  # Fallback on Windows (no symlinks): copy manifest to dist root
  cp "$RELEASE_DIR/manifest.json" "$DIST/manifest.json"
  echo "       (copied manifest.json to dist root)"
}

echo ""
echo "=== Release v${VERSION} built ==="
echo "  Release dir: $RELEASE_DIR"
echo "  Windows:     $([ -f $RELEASE_DIR/windows/crosslink-agent.zip ] && echo '✓' || echo '✗')"
echo "  Android:     $([ -f $RELEASE_DIR/android/crosslink.apk ] && echo '✓' || echo '✗')"
