#!/usr/bin/env bash
# CrossLink — health check for all services.
# Usage: bash scripts/check-services.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail(){ echo -e "  ${RED}[FAIL]${NC} $1 — $2"; }
warn(){ echo -e "  ${YELLOW}[WARN]${NC} $1"; }

PASS=0
FAIL=0

check_http() {
  local desc="$1" url="$2"
  if curl -sf --connect-timeout 5 "$url" > /dev/null 2>&1; then
    ok "$desc"; PASS=$((PASS+1))
  else
    fail "$desc" "$url unreachable"; FAIL=$((FAIL+1))
  fi
}

check_tcp() {
  local desc="$1" host="$2" port="$3"
  if timeout 3 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    ok "$desc"; PASS=$((PASS+1))
  else
    fail "$desc" "$host:$port unreachable"; FAIL=$((FAIL+1))
  fi
}

check_process() {
  local desc="$1" pattern="$2"
  if pgrep -f "$pattern" > /dev/null 2>&1; then
    ok "$desc (PID $(pgrep -f "$pattern" | head -1))"; PASS=$((PASS+1))
  else
    fail "$desc" "process not running"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "CrossLink Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""

# ---- Cloud Services ----
echo "Cloud (45.197.144.16):"
check_http "Signal server"     "http://45.197.144.16:18080/health"
check_tcp  "TURN TCP (3478)"   "45.197.144.16" "3478"
echo ""

# ---- Local Services ----
echo "Local:"
check_process "Agent" "ollama-agent.exe"
echo ""

# ---- API Connectivity ----
echo "External APIs:"
if [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc" 2>/dev/null || true
fi
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  if curl -sf --connect-timeout 10 https://api.deepseek.com/v1/models \
       -H "Authorization: Bearer $DEEPSEEK_API_KEY" > /dev/null 2>&1; then
    ok "DeepSeek API (key valid)"
    PASS=$((PASS+1))
  else
    fail "DeepSeek API" "auth failed or unreachable"
    FAIL=$((FAIL+1))
  fi
else
  warn "DeepSeek API (DEEPSEEK_API_KEY not set)"
fi
echo ""

# ---- Agent Details ----
echo "Agent details:"
if pgrep -f ollama-agent.exe > /dev/null 2>&1; then
  AGENT_LOG="/tmp/crosslink-agent.log"
  if [ -f "$AGENT_LOG" ]; then
    QR=$(grep "crosslink://pair" "$AGENT_LOG" 2>/dev/null | tail -1 | sed 's/.*crosslink/crosslink/' || echo "none")
    CONN=$(grep -c "connected to signaling" "$AGENT_LOG" 2>/dev/null || echo "0")
    echo "  Connected to signal: $([ "$CONN" -gt 0 ] && echo 'yes' || echo 'no')"
    echo "  Last QR: ${QR:0:80}..."
  fi
fi
echo ""

# ---- Summary ----
echo "========================================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}All checks passed!${NC}"
else
  echo -e "${RED}$FAIL check(s) failed — review above.${NC}"
fi
echo ""
