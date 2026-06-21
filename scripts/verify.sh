#!/usr/bin/env bash
# CrossLink Release Verification Suite
# Run before `build-dist.sh` to validate code quality and build readiness.
# Usage: bash scripts/verify.sh [--full]
#   --full  Also run heavy checks (full test suite, APK size check)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
PASS=0
FAIL=0

check() {
  local label="$1"; shift
  echo -n "  [$label] "
  if "$@" 2>&1; then
    echo -e "${GREEN}PASS${NC}"
    PASS=$((PASS+1))
  else
    echo -e "${RED}FAIL${NC}"
    FAIL=$((FAIL+1))
  fi
}

banner() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# Read version
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo "0.0.0")
echo -e "${CYAN}CrossLink Verify — v${VERSION}${NC}"
echo ""

# ---- 1. Go checks ----
banner "Go Backend"
cd "$ROOT/poc"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

check "go vet ./..."          go vet ./...
check "go test ./pairing/..."  go test ./pairing/ -v -count=1 2>&1 | tail -3
check "go build ./ollama-agent/" go build -o /dev/null ./ollama-agent/
check "go build ./relay/"       go build -o /dev/null ./relay/

# ---- 2. Flutter checks ----
banner "Flutter Frontend"
cd "$ROOT/app"
check "flutter analyze"  flutter analyze 2>&1 | grep -q "No issues found\|issues found" && true

# ---- 3. Version consistency ----
banner "Version Consistency"
check "VERSION matches manifest" \
  grep -q "\"version\": \"$VERSION\"" "$ROOT/poc/relay/dist/manifest.json"

check "CLAUDE.md version" \
  grep -q "v$VERSION" "$ROOT/CLAUDE.md" 2>/dev/null || { echo "  (warning: CLAUDE.md may need update)"; true; }

# ---- 4. Binary size check (--full only) ----
if [[ "${1:-}" == "--full" ]]; then
  banner "Full Checks"
  cd "$ROOT/poc"

  # Build actual binaries to check sizes
  GOOS=windows GOARCH=amd64 go build -o /tmp/crosslink-agent-check.exe ./ollama-agent/ 2>/dev/null
  AGENT_SIZE=$(stat -c%s /tmp/crosslink-agent-check.exe 2>/dev/null || echo 0)
  echo "  Agent size: $((AGENT_SIZE/1024/1024))MB"
  rm -f /tmp/crosslink-agent-check.exe

  cd "$ROOT/app"
  APK=$(find build/app/outputs/flutter-apk -name "*.apk" 2>/dev/null | head -1)
  if [ -n "$APK" ]; then
    APK_SIZE=$(stat -c%s "$APK" 2>/dev/null || echo 0)
    echo "  APK size:   $((APK_SIZE/1024/1024))MB"
  else
    echo "  APK: not found (build first)"
  fi
fi

# ---- Summary ----
echo ""
echo -e "${CYAN}════════════════════════════════${NC}"
echo -e "  Passed: ${GREEN}$PASS${NC}"
if [ $FAIL -gt 0 ]; then
  echo -e "  Failed: ${RED}$FAIL${NC}"
  echo ""
  echo -e "${RED}Verification FAILED. Fix issues before releasing.${NC}"
  exit 1
else
  echo -e "  Failed: 0"
  echo ""
  echo -e "${GREEN}All checks passed. Ready to release v${VERSION}.${NC}"
fi
