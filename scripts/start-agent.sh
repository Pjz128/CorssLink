#!/usr/bin/env bash
# CrossLink Agent — one-click startup with QR generation and health checks.
# Usage: bash scripts/start-agent.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$ROOT/poc/ollama-agent"
QRGEN_DIR="$ROOT/poc/qrgen"
AGENT_LOG="/tmp/crosslink-agent.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

banner()  { echo -e "${CYAN}=== $1 ===${NC}"; }
ok()      { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; }

echo ""
echo -e "${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│     CrossLink Agent Launcher v1.0        │${NC}"
echo -e "${CYAN}└──────────────────────────────────────────┘${NC}"
echo ""

# ---- Load API key ----
banner "Loading credentials"
if [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc" 2>/dev/null || true
fi
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  fail "DEEPSEEK_API_KEY not set in ~/.bashrc"
  echo "  Add:  export DEEPSEEK_API_KEY=sk-..."
  exit 1
fi
ok "DeepSeek API key loaded"

# ---- Config ----
SIGNAL_URL="${SIGNAL_URL:-ws://45.197.144.16:18080}"
AGENT_ID="${AGENT_ID:-agent-ollama-pc}"
export DEEPSEEK_API_KEY

# ---- Check cloud services ----
banner "Checking cloud services"

# Signal server
if curl -sf --connect-timeout 5 "${SIGNAL_URL/ws/http}/health" > /dev/null 2>&1; then
  ok "Signal server reachable"
else
  warn "Signal server ($SIGNAL_URL) not reachable — will keep retrying"
fi

# TURN server
TURN_HOST="$(echo "$SIGNAL_URL" | sed 's|ws://||;s|:.*||')"
if timeout 3 bash -c "echo > /dev/tcp/$TURN_HOST/3478" 2>/dev/null; then
  ok "TURN server TCP reachable (turn:$TURN_HOST:3478)"
else
  warn "TURN server port 3478 not reachable — P2P may fail"
fi

# DeepSeek API
if curl -sf --connect-timeout 10 https://api.deepseek.com/v1/models \
     -H "Authorization: Bearer $DEEPSEEK_API_KEY" > /dev/null 2>&1; then
  ok "DeepSeek API authenticated"
else
  fail "DeepSeek API unreachable or key invalid"
fi

# ---- Build agent ----
banner "Building agent"
cd "$AGENT_DIR"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
if go build -o ollama-agent.exe . 2>&1; then
  ok "Agent binary built"
else
  fail "Agent build failed"
  exit 1
fi

# ---- Stop old agent ----
banner "Starting agent"
if pgrep -f ollama-agent.exe > /dev/null 2>&1; then
  echo "  Stopping existing agent..."
  pkill -f ollama-agent.exe 2>/dev/null || true
  sleep 1
fi

# ---- Start agent ----
nohup env DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
  ./ollama-agent.exe > "$AGENT_LOG" 2>&1 &
AGENT_PID=$!
echo "  Agent PID: $AGENT_PID"

# ---- Wait for agent to connect ----
banner "Waiting for agent to connect"
for i in $(seq 1 15); do
  sleep 1
  if grep -q "connected to signaling" "$AGENT_LOG" 2>/dev/null; then
    ok "Agent connected to signal server"
    break
  fi
  if [ $i -eq 15 ]; then
    warn "Agent may not be connected yet — check logs"
  fi
done

# ---- Generate QR code ----
banner "Generating QR code"
sleep 1  # Let agent stabilize
QR_URI=$(grep "crosslink://pair" "$AGENT_LOG" 2>/dev/null | head -1 | sed 's/.*crosslink/crosslink/')

if [ -n "$QR_URI" ]; then
  # Update qrgen with current URI and generate PNG
  cd "$QRGEN_DIR"
  # Extract URI and update source
  ESCAPED_URI=$(echo "$QR_URI" | sed 's/|/\\|/g')
  # Generate QR image via Go
  go run main.go 2>&1 | tail -1
  ok "QR code saved to: $QRGEN_DIR/pairing-qr.png"
else
  warn "Could not extract QR URI from agent logs"
fi

# ---- Final health report ----
banner "Service Status"
echo ""
echo "  Signal:   $SIGNAL_URL"
echo "  TURN:     turn:$TURN_HOST:3478?transport=tcp"
echo "  Agent:    PID $AGENT_PID ($AGENT_ID)"
echo "  LLM API:  DeepSeek (deepseek-chat)"
echo "  QR code:  $QRGEN_DIR/pairing-qr.png"
echo ""
echo -e "${GREEN}Agent is running. Scan the QR code with the CrossLink App.${NC}"
echo "Logs: tail -f $AGENT_LOG"
echo ""
